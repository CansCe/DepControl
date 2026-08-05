/// Reads a repository's dependencies where the repository lives.
///
/// The library half of `depcontrol collect`, so the walk and the bundle it
/// produces can be tested without a process.
library;

export 'src/collector.dart';
export 'src/private_feeds.dart';
export 'src/version.dart';
