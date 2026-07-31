/// What a size figure actually measured.
///
/// The two registries answer a different question, and the difference is a
/// factor of three or four rather than a rounding error. Recording which one
/// was asked is what keeps a report from adding them together.
enum SizeBasis {
  /// Bytes the package occupies once installed, as the registry states them.
  ///
  /// npm publishes this as `dist.unpackedSize`, computed at publish time. It is
  /// the number a developer recognises: what `node_modules/<pkg>` weighs.
  unpacked,

  /// Bytes of the published archive, compressed.
  ///
  /// pub.dev publishes no size at all, so this is the `Content-Length` of the
  /// package's `.tar.gz`. Compressed source typically expands three to four
  /// times, so this understates disk cost — but by an unknown factor, and a
  /// guessed multiplier would turn a measurement into a fabrication.
  archive;

  /// Short label for a UI, naming the unit rather than implying they are one.
  String get label => switch (this) {
        SizeBasis.unpacked => 'installed',
        SizeBasis.archive => 'compressed',
      };

  /// One sentence on what this number is and is not, for a reader comparing
  /// two of them.
  String get caveat => switch (this) {
        SizeBasis.unpacked =>
          'Bytes on disk after install, as the registry recorded them at '
              'publish time.',
        SizeBasis.archive =>
          'The compressed download. pub.dev publishes no installed size, and '
              'source typically expands several times over, so the on-disk '
              'cost is higher by an amount nobody here measured.',
      };
}

/// The measured weight of one published package version.
///
/// This is install weight, not bundle weight. What survives tree-shaking and
/// minification into a production bundle depends on which symbols the project
/// imports and which bundler runs over them, and no registry knows either — the
/// tools that report bundle size run a bundler to find out. Presenting a
/// download size under that name would be wrong in the direction people act on.
class PackageSize {
  const PackageSize({
    required this.bytes,
    required this.basis,
    this.fileCount,
  });

  /// The measurement, in bytes, on the scale [basis] names.
  final int bytes;

  /// Which question the registry answered. Never drop this on the way to a
  /// sum — see [SizeTally].
  final SizeBasis basis;

  /// How many files the package ships, where the registry says.
  ///
  /// Worth carrying beside the bytes: ten thousand tiny files and one large
  /// one weigh the same and do not cost the same to install, and a package
  /// shipping its own test fixtures shows up here first.
  final int? fileCount;

  /// Human-readable bytes, in the units a package is actually discussed in.
  ///
  /// Binary multiples, since this describes files on disk. Sub-megabyte figures
  /// keep no decimal — the precision would be false comfort against a number
  /// the registry itself rounds.
  String get display => formatBytes(bytes);

  /// [bytes] rendered as `412 KB`, `1.4 MB`.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.round()} KB';
    final mb = kb / 1024;
    if (mb < 10) return '${mb.toStringAsFixed(1)} MB';
    return '${mb.round()} MB';
  }

  Map<String, dynamic> toJson() => {
        'bytes': bytes,
        'basis': basis.name,
        if (fileCount != null) 'fileCount': fileCount,
      };

  /// Reads a stored size, or null where the value is not one.
  ///
  /// Returns null rather than throwing on a malformed entry: a size is a
  /// nicety on a report whose advisories and licenses are the point, and one
  /// bad row must not make the rest of the report unreadable.
  static PackageSize? fromJson(Object? json) {
    if (json is! Map) return null;
    final bytes = json['bytes'];
    if (bytes is! int || bytes < 0) return null;
    final basis = SizeBasis.values
        .where((b) => b.name == json['basis'])
        .firstOrNull;
    if (basis == null) return null;
    final files = json['fileCount'];
    return PackageSize(
      bytes: bytes,
      basis: basis,
      fileCount: files is int && files >= 0 ? files : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PackageSize &&
      other.bytes == bytes &&
      other.basis == basis &&
      other.fileCount == fileCount;

  @override
  int get hashCode => Object.hash(bytes, basis, fileCount);

  @override
  String toString() => '$display (${basis.label})';
}

/// A sum of package sizes that refuses to add unlike things.
///
/// Totalling a report means totalling packages from more than one registry, and
/// npm's installed bytes and pub.dev's compressed bytes are not the same unit.
/// Rather than pick one and be quietly wrong, this keeps a subtotal per
/// [SizeBasis] and reports how many packages it could not measure at all.
///
/// [unmeasured] is not a footnote. npm records `unpackedSize` only for versions
/// published since it started doing so, which leaves exactly the small old
/// packages a dependency tree is full of — `sax` has it on 9 of 54 versions —
/// so a total that did not say how much it had missed would read as complete
/// when it was not.
class SizeTally {
  const SizeTally._(this._byBasis, this.measured, this.unmeasured);

  /// An empty tally: nothing measured, nothing missed.
  static const empty = SizeTally._({}, 0, 0);

  /// Sums [sizes], where a null entry counts towards [unmeasured].
  factory SizeTally.of(Iterable<PackageSize?> sizes) {
    final byBasis = <SizeBasis, int>{};
    var measured = 0;
    var unmeasured = 0;

    for (final size in sizes) {
      if (size == null) {
        unmeasured++;
        continue;
      }
      measured++;
      byBasis[size.basis] = (byBasis[size.basis] ?? 0) + size.bytes;
    }

    return SizeTally._(Map.unmodifiable(byBasis), measured, unmeasured);
  }

  final Map<SizeBasis, int> _byBasis;

  /// How many packages contributed a measurement.
  final int measured;

  /// How many had no size to contribute — the registry never recorded one, or
  /// the package does not come from a registry at all.
  final int unmeasured;

  /// Whether anything at all was measured.
  bool get isEmpty => measured == 0;

  /// Bytes on one scale, or zero where nothing was measured on it.
  int bytesOn(SizeBasis basis) => _byBasis[basis] ?? 0;

  /// The scales this tally holds anything on, in a stable order.
  List<SizeBasis> get bases =>
      SizeBasis.values.where(_byBasis.containsKey).toList();

  /// The subtotals, rendered as `1.4 MB installed`, joined by `+` where a
  /// report spans both registries.
  ///
  /// Deliberately not a single number. `1.4 MB installed + 210 KB compressed`
  /// is harder to read than `1.6 MB` and is the only one of the two that is
  /// true.
  String get display => bases
      .map((b) => '${PackageSize.formatBytes(bytesOn(b))} ${b.label}')
      .join(' + ');

  /// A caveat naming what the total left out, or null when it left out nothing.
  String? get shortfall => unmeasured == 0
      ? null
      : '$unmeasured of ${measured + unmeasured} packages publish no size, so '
          'the real figure is higher.';
}
