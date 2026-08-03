import 'dart:async';

/// A bounded cache of registry lookups, in flight or already made.
///
/// Two things separate it from a plain map, and a scan needs both.
///
/// It holds the *future* rather than the value, so several workers reaching for
/// the same package in the same instant share one request instead of racing to
/// make several. A dependency tree is mostly a small number of very popular
/// packages reached along many different paths, so that race is the normal case
/// rather than a corner of it.
///
/// And it is bounded. A registry client lives for the life of the server
/// process, which on a small machine makes an unbounded cache a slow way to run
/// out of memory — the same failure the caching was added to prevent. The least
/// recently used entry goes when the cap is reached, and the cost of a miss is
/// one request.
class RequestCache<K, V> {
  RequestCache({required this.capacity, required this.ttl})
      : assert(capacity > 0, 'A cache that can hold nothing is not a cache.');

  /// How many answers to keep. Sized by the caller, because a package document
  /// and a licence tag list are not the same weight.
  final int capacity;

  /// How long an answer stays good for.
  ///
  /// A server process outlives any one scan, and most of what a registry says
  /// is a fact about the rest of the world rather than about a fixed artefact:
  /// the newest release of a package changes when somebody else publishes, and
  /// an advisory appears when somebody else files it. Without an expiry this
  /// cache would turn a long-lived process into one that reports whatever was
  /// true when it started — a nightly rescan that never notices a new release
  /// is worse than a slow one.
  ///
  /// So the caller sets it against what it is caching. Minutes for anything
  /// the world can change underneath us, which is long enough that a whole
  /// scan is served from one lookup; hours for the things that genuinely
  /// cannot, like the size of an archive already published.
  final Duration ttl;

  /// Insertion-ordered, which Dart's default map guarantees — so the least
  /// recently used key is `keys.first`, and touching an entry means removing
  /// and reinserting it.
  final _entries = <K, _Entry<V>>{};

  /// How many answers are currently held. For tests and for reasoning about
  /// memory; nothing in the request path reads it.
  int get length => _entries.length;

  /// The answer for [key], from cache where there is one.
  ///
  /// [keep] decides whether an answer is worth remembering. It exists because
  /// "the registry has no such package" and "the registry did not answer" are
  /// different facts that arrive in the same shape: caching the second would
  /// turn one slow moment into a package that does not exist for the rest of
  /// the process's life. A [fetch] that throws is dropped for the same reason.
  Future<V> run(
    K key,
    Future<V> Function() fetch, {
    bool Function(V value) keep = _always,
  }) {
    final cached = _entries.remove(key);
    // An entry past its expiry is not an answer, and re-inserting it here is
    // what would make it immortal — every hit refreshing the thing that was
    // supposed to age out.
    if (cached != null && DateTime.now().difference(cached.at) < ttl) {
      return (_entries[key] = cached).future;
    }

    final entry = _Entry(fetch(), DateTime.now());
    _entries[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }

    return entry.future.then(
      (value) {
        if (!keep(value)) _forget(key, entry);
        return value;
      },
      onError: (Object error, StackTrace stack) {
        _forget(key, entry);
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  /// Drops [key], but only while it still holds [entry].
  ///
  /// An entry evicted and re-fetched between the request going out and the
  /// answer coming back is a newer answer than this one, and removing it would
  /// discard a good result on the strength of a stale failure.
  void _forget(K key, _Entry<V> entry) {
    if (identical(_entries[key], entry)) _entries.remove(key);
  }

  void clear() => _entries.clear();

  static bool _always(Object? value) => true;
}

/// One lookup, and when it was made.
class _Entry<V> {
  _Entry(this.future, this.at);

  final Future<V> future;

  /// When the request went out, not when it came back — an answer is as old as
  /// the question that produced it.
  final DateTime at;
}
