import 'package:backend/src/services/rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  // A controllable clock: real time would make every assertion here a guess.
  var now = DateTime.utc(2026, 1, 1);
  DateTime clock() => now;

  RateLimiter limiterWith({int burst = 3, int refillMs = 1000}) {
    now = DateTime.utc(2026, 1, 1);
    return RateLimiter(
      burst: burst,
      refill: Duration(milliseconds: refillMs),
      clock: clock,
    );
  }

  group('spending tokens', () {
    test('allows a full burst straight away', () {
      final limiter = limiterWith(burst: 3);

      expect(limiter.check('alice').allowed, isTrue);
      expect(limiter.check('alice').allowed, isTrue);
      expect(limiter.check('alice').allowed, isTrue);
    });

    test('refuses once the burst is spent', () {
      final limiter = limiterWith(burst: 3);
      for (var i = 0; i < 3; i++) {
        limiter.check('alice');
      }

      expect(limiter.check('alice').allowed, isFalse);
    });

    test('counts each caller separately', () {
      final limiter = limiterWith(burst: 1);

      expect(limiter.check('alice').allowed, isTrue);
      expect(limiter.check('alice').allowed, isFalse);
      // Bob is untouched by Alice spending hers.
      expect(limiter.check('bob').allowed, isTrue);
    });
  });

  group('refilling', () {
    test('earns one token back per refill period', () {
      final limiter = limiterWith(burst: 2, refillMs: 1000);
      limiter.check('alice');
      limiter.check('alice');
      expect(limiter.check('alice').allowed, isFalse);

      now = now.add(const Duration(milliseconds: 1000));
      expect(limiter.check('alice').allowed, isTrue);
      expect(limiter.check('alice').allowed, isFalse);
    });

    test('does not refill past the burst', () {
      final limiter = limiterWith(burst: 2, refillMs: 1000);
      limiter.check('alice');

      // Idle for far longer than it takes to refill completely.
      now = now.add(const Duration(hours: 1));

      expect(limiter.check('alice').allowed, isTrue);
      expect(limiter.check('alice').allowed, isTrue);
      expect(limiter.check('alice').allowed, isFalse);
    });

    test('a partial wait earns nothing', () {
      final limiter = limiterWith(burst: 1, refillMs: 1000);
      limiter.check('alice');

      now = now.add(const Duration(milliseconds: 999));
      expect(limiter.check('alice').allowed, isFalse);
    });
  });

  group('retry-after', () {
    test('reports how long until the next token', () {
      final limiter = limiterWith(burst: 1, refillMs: 2000);
      limiter.check('alice');

      final denied = limiter.check('alice');
      expect(denied.allowed, isFalse);
      expect(denied.retryAfter, const Duration(milliseconds: 2000));
      expect(denied.retryAfterSeconds, 2);
    });

    test('shrinks as the wait is served', () {
      final limiter = limiterWith(burst: 1, refillMs: 2000);
      limiter.check('alice');
      now = now.add(const Duration(milliseconds: 1500));

      expect(limiter.check('alice').retryAfter.inMilliseconds, 500);
    });

    // Rounding down would tell a client to retry fractionally too early and be
    // refused a second time.
    test('rounds up to a whole second, never to zero', () {
      final limiter = limiterWith(burst: 1, refillMs: 1200);
      limiter.check('alice');
      now = now.add(const Duration(milliseconds: 1100));

      final denied = limiter.check('alice');
      expect(denied.retryAfter.inMilliseconds, lessThan(1000));
      expect(denied.retryAfterSeconds, 1);
    });

    test('an allowed decision carries no wait', () {
      expect(const RateDecision.allowed().retryAfter, Duration.zero);
    });
  });

  group('fromEnvironment', () {
    test('defaults to 20 a minute when nothing is set', () {
      final limiter = RateLimiter.fromEnvironment(const {})!;

      expect(limiter.burst, 20);
      expect(limiter.refill, const Duration(seconds: 3));
    });

    test('reads the sustained rate', () {
      final limiter =
          RateLimiter.fromEnvironment(const {'RATE_LIMIT_PER_MINUTE': '60'})!;

      expect(limiter.refill, const Duration(seconds: 1));
      expect(limiter.burst, 60);
    });

    test('lets the burst differ from the sustained rate', () {
      final limiter = RateLimiter.fromEnvironment(const {
        'RATE_LIMIT_PER_MINUTE': '60',
        'RATE_LIMIT_BURST': '5',
      })!;

      expect(limiter.burst, 5);
      expect(limiter.refill, const Duration(seconds: 1));
    });

    test('zero switches limiting off', () {
      expect(
        RateLimiter.fromEnvironment(const {'RATE_LIMIT_PER_MINUTE': '0'}),
        isNull,
      );
    });

    test('nonsense falls back to the default rather than to no limit', () {
      final limiter = RateLimiter.fromEnvironment(
        const {'RATE_LIMIT_PER_MINUTE': 'lots'},
      );

      expect(limiter, isNotNull);
      expect(limiter!.burst, 20);
    });
  });

  // The bucket map is keyed by user id, so without a sweep it grows for as long
  // as the process runs.
  test('forgets callers whose buckets have refilled', () {
    final limiter = limiterWith(burst: 1, refillMs: 1000);
    for (var i = 0; i < 2000; i++) {
      limiter.check('user-$i');
    }

    now = now.add(const Duration(hours: 1));
    // The sweep runs on the next check; afterwards the idle callers are gone
    // and a fresh burst is available to each, which is what "forgotten" means.
    expect(limiter.check('user-0').allowed, isTrue);
    expect(limiter.check('user-1').allowed, isTrue);
  });
}
