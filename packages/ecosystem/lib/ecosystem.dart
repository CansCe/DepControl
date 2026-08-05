/// Manifest parsing for every ecosystem DepControl understands.
///
/// Nothing here reaches the network. Registry access — which host publishes a
/// package, what it says about a version, which advisories apply — lives with
/// whoever owns the credentials and the connection pool, which is the server.
/// The split is what lets the local collector parse a repository on a
/// developer's own machine using exactly the code the server would have used.
library;

export 'src/dart/dart_ecosystem.dart';
export 'src/dart/import_scanner.dart';
export 'src/discovery.dart';
export 'src/ecosystem.dart';
export 'src/manifest.dart';
export 'src/npm/js_source_scanner.dart';
export 'src/npm/npm_ecosystem.dart';
export 'src/npm/npm_version_range.dart';
export 'src/nuget/dotnet_source_scanner.dart';
export 'src/nuget/nuget_ecosystem.dart';
export 'src/nuget/nuget_version.dart';
export 'src/nuget/nuget_version_range.dart';
