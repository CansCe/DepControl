import 'package:flutter/material.dart';

/// DepControl's palette, type scale and component defaults.
///
/// The palette is anchored on **semver**, because that is the one structure
/// this whole product is about: every screen exists to answer "which field of
/// `MAJOR.MINOR.PATCH` would move, and can you afford it". The three fields get
/// three hues and keep them everywhere, so a colour learned in one place reads
/// the same in the next.
///
/// Breaking is magenta rather than red on purpose. Red already means
/// *vulnerable* in this app, and a major version bump is not a vulnerability —
/// it is work. Giving them the same colour was quietly telling the reader that
/// six breaking upgrades and six CVEs are the same kind of news.
///
/// Two palettes deliberately sit outside this one, because they answer to
/// different people: advisory severity keeps the CVSS ramp (`severity_chip`)
/// and license verdicts keep stop / think / go (`license_chip`). Which of the
/// three you are reading is carried by the coloured spine on each card rather
/// than by asking the colours to do double duty.
abstract final class Palette {
  /// Chrome and headings. Deep enough to sit under white text, blue enough not
  /// to read as a default black.
  static const ink = Color(0xFF151B2E);

  /// The ink band's lighter partner — rules and inset panels drawn on it.
  static const inkSoft = Color(0xFF27314D);

  /// Brand and primary action. The ecosystem's blue, opened up a stop from
  /// Dart's own `#0553B1` so it survives being used on ink.
  static const pub = Color(0xFF2C6FE4);

  /// MAJOR: a breaking change. Work, not danger.
  static const major = Color(0xFFD6336C);

  /// MINOR: additive. Worth taking, worth a glance.
  static const minor = Color(0xFFB26A00);

  /// PATCH: safe, and by extension "nothing to do here".
  static const patch = Color(0xFF0E8A6A);

  /// Secondary text.
  static const slate = Color(0xFF5B6580);

  /// [minor] and the advisory red, re-tuned for the ink band.
  ///
  /// A hue chosen to carry weight against white paper goes muddy against navy —
  /// `#B26A00` on ink is a dark smear next to white, and the reader stops
  /// seeing it as a signal at all. Same meaning, same position on the wheel,
  /// lifted until it reads.
  static const minorOnInk = Color(0xFFF2A93B);
  static const alarmOnInk = Color(0xFFFF7A85);

  /// The page under the cards, and the fill of anything inset.
  static const mist = Color(0xFFEEF1F8);

  /// Card and table surface.
  static const paper = Color(0xFFFFFFFF);
}

/// Display face: flat, mechanical terminals — an instrument panel rather than
/// an editorial page. Used only for screen and section titles.
const kDisplayFont = 'Archivo';

/// Body face. Humanist but engineered, and it holds its shape at the 12–13px
/// this app spends most of its time at.
const kBodyFont = 'IBM Plex Sans';

/// Data face. See [mono] — this one carries meaning, not flavour.
const kMonoFont = 'IBM Plex Mono';

const _displayFallback = ['Archivo', 'Segoe UI', 'Roboto', 'sans-serif'];
const _bodyFallback = ['Segoe UI', 'Roboto', 'Helvetica', 'sans-serif'];
const _monoFallback = ['Consolas', 'Menlo', 'Courier New', 'monospace'];

/// Sets text in the data face.
///
/// The rule, applied everywhere: **anything a machine assigned is monospaced** —
/// versions, constraints, GHSA and CVE identifiers, CVSS vectors, SPDX ids, git
/// URLs, manifest paths. Anything a person wrote is not. That is not a texture
/// choice; it tells the reader at a glance which strings they are expected to
/// match character by character, and those are exactly the strings this app
/// asks them to trust.
TextStyle mono(TextStyle? base, {Color? color, FontWeight? weight}) =>
    (base ?? const TextStyle()).copyWith(
      fontFamily: kMonoFont,
      fontFamilyFallback: _monoFallback,
      color: color,
      fontWeight: weight,
      // Plex Mono runs large for its point size next to Plex Sans; a hair
      // smaller keeps a version string from outweighing the package name it
      // belongs to.
      fontSize: (base?.fontSize ?? 14) - 0.5,
      letterSpacing: 0,
    );

/// Sets text in the display face.
TextStyle display(TextStyle? base, {Color? color, FontWeight? weight}) =>
    (base ?? const TextStyle()).copyWith(
      fontFamily: kDisplayFont,
      fontFamilyFallback: _displayFallback,
      color: color,
      fontWeight: weight ?? FontWeight.w700,
      // Archivo is drawn tight; letting it default to normal tracking loses the
      // compactness that makes it read as an instrument label.
      letterSpacing: -0.4,
    );

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Palette.pub,
    primary: Palette.pub,
    surface: Palette.paper,
    error: const Color(0xFFB3261E),
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  final text = base.textTheme
      .apply(
        fontFamily: kBodyFont,
        fontFamilyFallback: _bodyFallback,
        bodyColor: Palette.ink,
        displayColor: Palette.ink,
      )
      .copyWith(
        headlineMedium: display(base.textTheme.headlineMedium),
        headlineSmall: display(base.textTheme.headlineSmall),
        titleLarge: display(base.textTheme.titleLarge),
        titleMedium: display(base.textTheme.titleMedium, weight: FontWeight.w600),
        titleSmall: display(base.textTheme.titleSmall, weight: FontWeight.w600),
      );

  return base.copyWith(
    scaffoldBackgroundColor: Palette.mist,
    textTheme: text,
    primaryTextTheme: text,
    dividerTheme: DividerThemeData(
      color: Palette.ink.withValues(alpha: 0.10),
      space: 1,
      thickness: 1,
    ),
    // The app bar is part of the ink band on both screens, so it contributes a
    // title and actions and nothing else — no surface, no shadow, no seam
    // across the band it sits in.
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: Colors.white,
      titleTextStyle: display(text.titleLarge, color: Colors.white),
      iconTheme: const IconThemeData(color: Colors.white),
    ),
    cardTheme: CardThemeData(
      color: Palette.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Palette.ink.withValues(alpha: 0.10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.paper,
      border: _fieldBorder(Palette.ink.withValues(alpha: 0.18)),
      enabledBorder: _fieldBorder(Palette.ink.withValues(alpha: 0.18)),
      focusedBorder: _fieldBorder(Palette.pub, width: 1.6),
      labelStyle: const TextStyle(color: Palette.slate),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.pub,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: display(text.labelLarge, weight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.ink,
        side: BorderSide(color: Palette.ink.withValues(alpha: 0.22)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: display(
        text.labelMedium,
        color: Palette.slate,
        weight: FontWeight.w600,
      ),
      dataTextStyle: text.bodyMedium,
      dividerThickness: 1,
      headingRowColor: WidgetStatePropertyAll(Palette.mist.withValues(alpha: 0.7)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.ink,
      contentTextStyle: const TextStyle(
        fontFamily: kBodyFont,
        color: Colors.white,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: display(text.titleLarge),
    ),
  );
}

OutlineInputBorder _fieldBorder(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color, width: width),
    );
