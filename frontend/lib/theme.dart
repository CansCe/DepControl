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

/// The console build's palette: the same app, drawn for a dark room.
///
/// Only the *neutrals* are new. The three judgement hues keep the meanings
/// [Palette] gives them — they are simply lifted until they survive a navy
/// background, the way [Palette.minorOnInk] already had to be.
abstract final class Console {
  /// The header rail and the deepest inset — under the page, not on it.
  static const abyss = Color(0xFF010F1F);

  /// The page itself.
  static const bg = Color(0xFF051424);

  /// The sidebar, and cards that sit directly on [bg].
  static const sidebar = Color(0xFF0D1C2D);

  /// Content cards inside the main column.
  static const card = Color(0xFF122131);

  /// Raised controls — secondary buttons, icon wells.
  static const raised = Color(0xFF1C2B3C);

  /// Chip and tag fill.
  static const chip = Color(0xFF273647);

  /// Every rule and border.
  static const line = Color(0xFF434655);

  /// Primary text.
  static const text = Color(0xFFD4E4FA);

  /// Secondary text.
  static const muted = Color(0xFFC3C6D7);

  /// Text that has gone quiet — disabled, or a dot for an unselected row.
  static const faint = Color(0xFF8D90A0);

  /// Brand and primary action.
  static const accent = Color(0xFFB4C5FF);

  /// What reads on [accent].
  static const onAccent = Color(0xFF002A78);

  /// MAJOR, lifted. Fuchsia rather than the light theme's rose, because at this
  /// brightness rose and the advisory red converge — and those two staying
  /// apart is the entire reason [Palette.major] is not red to begin with.
  static const major = Color(0xFFE879F9);

  /// MINOR and PATCH, at dark-room brightness.
  static const minor = Color(0xFFF2A93B);
  static const patch = Color(0xFF34D399);

  /// The advisory red.
  static const alarm = Color(0xFFFF7A85);
}

/// The three roles this app sets type in, and which family fills each.
///
/// Two sets, because the browser build now has two skins. What does *not*
/// change between them is the rule the roles encode: a display face for titles,
/// a body face for prose, and a mono face for every string a machine assigned.
/// Swapping the faces restyles the app; it does not restate what monospace
/// means here.
@immutable
class Faces {
  const Faces({
    required this.display,
    required this.body,
    required this.mono,
    required this.displayTracking,
    required this.monoTrim,
  });

  final String display;
  final String body;
  final String mono;

  /// How tight the display face wants to be set.
  final double displayTracking;

  /// How far the mono face has to come down to match the body face beside it.
  ///
  /// Plex Mono runs large for its point size next to Plex Sans; JetBrains Mono
  /// runs larger still next to Geist, so it gives back more.
  final double monoTrim;

  /// The original: Archivo titles, Plex prose, Plex data.
  static const plex = Faces(
    display: 'Archivo',
    body: 'IBM Plex Sans',
    mono: 'IBM Plex Mono',
    displayTracking: -0.4,
    monoTrim: 0.5,
  );

  /// The console: Geist throughout, JetBrains Mono for data.
  static const geist = Faces(
    display: 'Geist',
    body: 'Geist',
    mono: 'JetBrains Mono',
    // Geist is already drawn tight; Archivo's -0.4 would close it up.
    displayTracking: -0.2,
    monoTrim: 1,
  );

  List<String> get displayFallback => [display, 'Segoe UI', 'Roboto', 'sans-serif'];
  List<String> get bodyFallback => [body, 'Segoe UI', 'Roboto', 'Helvetica', 'sans-serif'];
  List<String> get monoFallback => [mono, 'Consolas', 'Menlo', 'Courier New', 'monospace'];
}

/// The colours a widget needs that a [ColorScheme] has no slot for.
///
/// This exists because the app now ships two skins of the same screens, and
/// almost every widget below the shell was written against [Palette] directly —
/// `Palette.paper` for a card, `Palette.ink` for body text. Those are correct
/// on white paper and wrong on navy, and a widget cannot tell which it is on.
///
/// Resolving them through the theme is what lets one `DepTable` render in both
/// without a `isDark` branch at every call site: the slot means "the card
/// surface", and each theme says what that is.
@immutable
class Surfaces extends ThemeExtension<Surfaces> {
  const Surfaces({
    required this.page,
    required this.card,
    required this.inset,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.onAccent,
    required this.major,
    required this.minor,
    required this.patch,
    required this.alarm,
    required this.isDark,
    required this.faces,
  });

  /// The scaffold behind the cards.
  final Color page;

  /// A card, a table, anything the reader thinks of as the sheet.
  final Color card;

  /// A panel inset *into* a card — quieter than the card, not louder.
  final Color inset;

  /// Raised controls sitting on a card.
  final Color raised;

  /// Rules, borders, dividers.
  final Color line;

  /// Body text.
  final Color text;

  /// Secondary text.
  final Color muted;

  /// Text that has gone quiet.
  final Color faint;

  final Color accent;
  final Color onAccent;

  /// The semver triad and the advisory red, at this theme's brightness.
  final Color major;
  final Color minor;
  final Color patch;
  final Color alarm;

  final bool isDark;

  /// Which type system this skin sets.
  final Faces faces;

  /// A hairline at whatever weight reads on this theme's card.
  ///
  /// A border that works on white is invisible on navy at the same alpha, and
  /// one that works on navy is a black scar on white.
  Color get hairline => isDark ? line : text.withValues(alpha: 0.10);

  /// The fill for a tinted callout in [accent], or in any [hue] given.
  Color wash(Color hue) => hue.withValues(alpha: isDark ? 0.10 : 0.08);

  static Surfaces of(BuildContext context) =>
      Theme.of(context).extension<Surfaces>() ?? light;

  static const light = Surfaces(
    page: Palette.mist,
    card: Palette.paper,
    inset: Palette.mist,
    raised: Palette.paper,
    line: Color(0xFFD8DEEC),
    text: Palette.ink,
    muted: Palette.slate,
    faint: Palette.slate,
    accent: Palette.pub,
    onAccent: Colors.white,
    major: Palette.major,
    minor: Palette.minor,
    patch: Palette.patch,
    alarm: Color(0xFFC62828),
    isDark: false,
    faces: Faces.plex,
  );

  static const dark = Surfaces(
    page: Console.bg,
    card: Console.card,
    inset: Console.abyss,
    raised: Console.raised,
    line: Console.line,
    text: Console.text,
    muted: Console.muted,
    faint: Console.faint,
    accent: Console.accent,
    onAccent: Console.onAccent,
    major: Console.major,
    minor: Console.minor,
    patch: Console.patch,
    alarm: Console.alarm,
    isDark: true,
    faces: Faces.geist,
  );

  @override
  Surfaces copyWith({
    Color? page,
    Color? card,
    Color? inset,
    Color? raised,
    Color? line,
    Color? text,
    Color? muted,
    Color? faint,
    Color? accent,
    Color? onAccent,
    Color? major,
    Color? minor,
    Color? patch,
    Color? alarm,
    bool? isDark,
    Faces? faces,
  }) {
    return Surfaces(
      page: page ?? this.page,
      card: card ?? this.card,
      inset: inset ?? this.inset,
      raised: raised ?? this.raised,
      line: line ?? this.line,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      faint: faint ?? this.faint,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      major: major ?? this.major,
      minor: minor ?? this.minor,
      patch: patch ?? this.patch,
      alarm: alarm ?? this.alarm,
      isDark: isDark ?? this.isDark,
      faces: faces ?? this.faces,
    );
  }

  /// Never interpolated in practice — the two skins swap at a breakpoint rather
  /// than cross-fading — but a [ThemeExtension] has to be able to.
  @override
  Surfaces lerp(covariant Surfaces? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return Surfaces(
      page: mix(page, other.page),
      card: mix(card, other.card),
      inset: mix(inset, other.inset),
      raised: mix(raised, other.raised),
      line: mix(line, other.line),
      text: mix(text, other.text),
      muted: mix(muted, other.muted),
      faint: mix(faint, other.faint),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      major: mix(major, other.major),
      minor: mix(minor, other.minor),
      patch: mix(patch, other.patch),
      alarm: mix(alarm, other.alarm),
      isDark: t < 0.5 ? isDark : other.isDark,
      faces: t < 0.5 ? faces : other.faces,
    );
  }
}

/// Display face: flat, mechanical terminals — an instrument panel rather than
/// an editorial page. Used only for screen and section titles.
const kDisplayFont = 'Archivo';

/// Body face. Humanist but engineered, and it holds its shape at the 12–13px
/// this app spends most of its time at.
const kBodyFont = 'IBM Plex Sans';

/// Data face. See [mono] — this one carries meaning, not flavour.
const kMonoFont = 'IBM Plex Mono';

/// Sets text in the data face.
///
/// The rule, applied everywhere: **anything a machine assigned is monospaced** —
/// versions, constraints, GHSA and CVE identifiers, CVSS vectors, SPDX ids, git
/// URLs, manifest paths. Anything a person wrote is not. That is not a texture
/// choice; it tells the reader at a glance which strings they are expected to
/// match character by character, and those are exactly the strings this app
/// asks them to trust.
TextStyle mono(
  TextStyle? base, {
  Color? color,
  FontWeight? weight,
  Faces faces = Faces.plex,
}) =>
    (base ?? const TextStyle()).copyWith(
      fontFamily: faces.mono,
      fontFamilyFallback: faces.monoFallback,
      color: color,
      fontWeight: weight,
      // A mono face runs large for its point size next to the body face beside
      // it; a hair smaller keeps a version string from outweighing the package
      // name it belongs to.
      fontSize: (base?.fontSize ?? 14) - faces.monoTrim,
      letterSpacing: 0,
    );

/// Sets text in the display face.
TextStyle display(
  TextStyle? base, {
  Color? color,
  FontWeight? weight,
  Faces faces = Faces.plex,
}) =>
    (base ?? const TextStyle()).copyWith(
      fontFamily: faces.display,
      fontFamilyFallback: faces.displayFallback,
      color: color,
      fontWeight: weight ?? FontWeight.w700,
      // These faces are drawn tight; letting them default to normal tracking
      // loses the compactness that makes them read as an instrument label.
      letterSpacing: faces.displayTracking,
    );

/// [mono], in whichever faces the surrounding skin sets.
///
/// The `…Of` pair exists because a widget below the shell renders in both
/// skins and cannot know which. Prefer these anywhere a [BuildContext] is in
/// hand; the bare [mono] and [display] remain for the const-ish cases that have
/// no context to ask.
TextStyle monoOf(
  BuildContext context,
  TextStyle? base, {
  Color? color,
  FontWeight? weight,
}) =>
    mono(base, color: color, weight: weight, faces: Surfaces.of(context).faces);

/// [display], in whichever faces the surrounding skin sets.
TextStyle displayOf(
  BuildContext context,
  TextStyle? base, {
  Color? color,
  FontWeight? weight,
}) =>
    display(base,
        color: color, weight: weight, faces: Surfaces.of(context).faces);

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
        fontFamily: Faces.plex.body,
        fontFamilyFallback: Faces.plex.bodyFallback,
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
    extensions: const [Surfaces.light],
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

/// The wide browser's skin: the same app in a dark console.
///
/// Not a `Brightness.dark` variant of [buildTheme] — it is a different room.
/// The light theme is a report printed on paper; this one is an operations
/// console someone leaves open on a second monitor all day, and it is chosen by
/// window width rather than by a user preference, because that is the only
/// thing that reliably distinguishes the two uses.
///
/// Everything structural is shared: the same [Surfaces] slots, the same rule
/// about what gets set in mono, the same three judgement hues meaning the same
/// three things.
ThemeData buildConsoleTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Console.accent,
    brightness: Brightness.dark,
    primary: Console.accent,
    onPrimary: Console.onAccent,
    surface: Console.card,
    onSurface: Console.text,
    error: Console.alarm,
    onError: Console.abyss,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  const faces = Faces.geist;

  final text = base.textTheme
      .apply(
        fontFamily: faces.body,
        fontFamilyFallback: faces.bodyFallback,
        bodyColor: Console.text,
        displayColor: Console.text,
      )
      .copyWith(
        headlineMedium: display(base.textTheme.headlineMedium,
            faces: faces, weight: FontWeight.w600),
        headlineSmall: display(base.textTheme.headlineSmall,
            faces: faces, weight: FontWeight.w600),
        titleLarge:
            display(base.textTheme.titleLarge, faces: faces, weight: FontWeight.w600),
        titleMedium: display(base.textTheme.titleMedium,
            faces: faces, weight: FontWeight.w600),
        titleSmall: display(base.textTheme.titleSmall,
            faces: faces, weight: FontWeight.w600),
      );

  return base.copyWith(
    extensions: const [Surfaces.dark],
    scaffoldBackgroundColor: Console.bg,
    canvasColor: Console.bg,
    textTheme: text,
    primaryTextTheme: text,
    dividerTheme: const DividerThemeData(
      color: Console.line,
      space: 1,
      thickness: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Console.abyss,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: Console.text,
      titleTextStyle: display(text.titleLarge, faces: faces, color: Console.text),
      iconTheme: const IconThemeData(color: Console.muted),
    ),
    cardTheme: CardThemeData(
      color: Console.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Console.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // Fields sink into the page rather than sitting on it — the opposite of
      // the light theme, where a white field on grey is what raises it.
      fillColor: Console.abyss,
      border: _fieldBorder(Console.line),
      enabledBorder: _fieldBorder(Console.line),
      focusedBorder: _fieldBorder(Console.accent, width: 1.6),
      labelStyle: const TextStyle(color: Console.muted),
      hintStyle: const TextStyle(color: Console.faint),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Console.accent,
        foregroundColor: Console.onAccent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: display(text.labelLarge, faces: faces, weight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Console.text,
        backgroundColor: Console.raised,
        side: const BorderSide(color: Console.line),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Console.accent),
    ),
    iconTheme: const IconThemeData(color: Console.muted),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: mono(
        text.labelMedium,
        faces: faces,
        color: Console.muted,
        weight: FontWeight.w600,
      ).copyWith(letterSpacing: 0.5),
      dataTextStyle: text.bodyMedium,
      dividerThickness: 1,
      headingRowColor: const WidgetStatePropertyAll(Console.abyss),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Console.sidebar,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Console.sidebar,
      contentTextStyle: const TextStyle(
        fontFamily: 'Geist',
        color: Console.text,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Console.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Console.sidebar,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Console.line),
      ),
      titleTextStyle: display(text.titleLarge, faces: faces),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Console.abyss,
        border: Border.all(color: Console.line),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: Console.text, fontSize: 12),
    ),
  );
}

OutlineInputBorder _fieldBorder(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color, width: width),
    );
