import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// The public declarations of one package version, as `name -> signature`.
///
/// Signatures are compared as text rather than resolved types, so renaming a
/// type alias reads as a change. That errs towards reporting a difference,
/// which is the safer direction for a breakage check.
typedef ApiSurface = Map<String, String>;

/// What happened to one declaration between two versions.
enum ApiChangeKind { removed, changed, added }

class ApiChange {
  const ApiChange({
    required this.kind,
    required this.declaration,
    this.before,
    this.after,
  });

  final ApiChangeKind kind;

  /// Qualified name, e.g. `Client.send` or `parseResponse`.
  final String declaration;
  final String? before;
  final String? after;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'declaration': declaration,
        'before': before,
        'after': after,
      };

  @override
  String toString() => switch (kind) {
        ApiChangeKind.removed => '- $declaration',
        ApiChangeKind.added => '+ $declaration',
        ApiChangeKind.changed => '~ $declaration: $before -> $after',
      };
}

/// Compares two surfaces, removals first.
List<ApiChange> diffSurfaces(ApiSurface before, ApiSurface after) {
  final changes = <ApiChange>[];

  for (final entry in before.entries) {
    final now = after[entry.key];
    if (now == null) {
      changes.add(
        ApiChange(
          kind: ApiChangeKind.removed,
          declaration: entry.key,
          before: entry.value,
        ),
      );
    } else if (now != entry.value) {
      changes.add(
        ApiChange(
          kind: ApiChangeKind.changed,
          declaration: entry.key,
          before: entry.value,
          after: now,
        ),
      );
    }
  }

  for (final entry in after.entries) {
    if (before.containsKey(entry.key)) continue;
    changes.add(
      ApiChange(
        kind: ApiChangeKind.added,
        declaration: entry.key,
        after: entry.value,
      ),
    );
  }

  changes.sort((a, b) {
    final byKind = a.kind.index.compareTo(b.kind.index);
    return byKind != 0 ? byKind : a.declaration.compareTo(b.declaration);
  });
  return changes;
}

/// Builds the public surface from a package's `lib/` sources.
///
/// Only files reachable from the package's entry points count: `lib/src/**` is
/// implementation detail unless an entry point exports it, so export directives
/// are followed to a fixed point rather than treating every file as public.
ApiSurface extractSurface(Map<String, String> libSources) {
  final surface = <String, String>{};

  for (final path in _reachableFiles(libSources)) {
    final unit = _parse(libSources[path]);
    if (unit == null) continue;
    for (final declaration in unit.declarations) {
      _collect(declaration, surface);
    }
  }

  return surface;
}

CompilationUnit? _parse(String? source) {
  if (source == null) return null;
  try {
    return parseString(content: source, throwIfDiagnostics: false).unit;
  } catch (_) {
    // An unparseable file is skipped rather than losing the whole package.
    return null;
  }
}

Set<String> _reachableFiles(Map<String, String> sources) {
  // `lib/*.dart` outside lib/src are the package's entry points.
  final queue = sources.keys
      .where((f) => !f.startsWith('lib/src/') && f.endsWith('.dart'))
      .toList();
  final reachable = <String>{...queue};

  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    final unit = _parse(sources[path]);
    if (unit == null) continue;

    for (final directive in unit.directives.whereType<ExportDirective>()) {
      final target = directive.uri.stringValue;
      if (target == null || target.contains(':')) continue; // package:/dart:

      final resolved = p.url.normalize(p.url.join(p.url.dirname(path), target));
      if (sources.containsKey(resolved) && reachable.add(resolved)) {
        queue.add(resolved);
      }
    }
  }

  return reachable;
}

bool _isPublic(String name) => !name.startsWith('_');

void _collect(CompilationUnitMember declaration, ApiSurface surface) {
  if (declaration is ClassDeclaration) {
    _collectType(
      kind: declaration.abstractKeyword != null ? 'abstract class' : 'class',
      name: declaration.name.lexeme,
      members: declaration.members,
      surface: surface,
    );
  } else if (declaration is MixinDeclaration) {
    _collectType(
      kind: 'mixin',
      name: declaration.name.lexeme,
      members: declaration.members,
      surface: surface,
    );
  } else if (declaration is ExtensionDeclaration) {
    final name = declaration.name?.lexeme;
    if (name == null) return;
    _collectType(
      kind: 'extension',
      name: name,
      members: declaration.members,
      surface: surface,
    );
  } else if (declaration is EnumDeclaration) {
    final name = declaration.name.lexeme;
    if (!_isPublic(name)) return;
    // Enum constants are part of the contract: removing one breaks switches.
    surface['enum $name'] =
        declaration.constants.map((c) => c.name.lexeme).join(', ');
  } else if (declaration is FunctionDeclaration) {
    final name = declaration.name.lexeme;
    if (!_isPublic(name)) return;
    final returns = declaration.returnType?.toSource() ?? 'dynamic';
    final params = declaration.functionExpression.parameters?.toSource() ?? '()';
    surface[name] = '$returns $params';
  } else if (declaration is TopLevelVariableDeclaration) {
    for (final variable in declaration.variables.variables) {
      final name = variable.name.lexeme;
      if (!_isPublic(name)) continue;
      surface[name] = declaration.variables.type?.toSource() ?? 'var';
    }
  } else if (declaration is TypeAlias) {
    final name = declaration.name.lexeme;
    if (_isPublic(name)) surface['typedef $name'] = declaration.toSource();
  }
}

void _collectType({
  required String kind,
  required String name,
  required List<ClassMember> members,
  required ApiSurface surface,
}) {
  if (!_isPublic(name)) return;
  surface['$kind $name'] = name;

  for (final member in members) {
    if (member is MethodDeclaration) {
      final memberName = member.name.lexeme;
      if (!_isPublic(memberName)) continue;
      final returns = member.returnType?.toSource() ?? 'dynamic';
      surface['$name.$memberName'] = member.isGetter
          ? '$returns get'
          : '$returns ${member.parameters?.toSource() ?? '()'}';
    } else if (member is FieldDeclaration) {
      for (final field in member.fields.variables) {
        final fieldName = field.name.lexeme;
        if (!_isPublic(fieldName)) continue;
        surface['$name.$fieldName'] = member.fields.type?.toSource() ?? 'var';
      }
    } else if (member is ConstructorDeclaration) {
      final ctor = member.name?.lexeme;
      if (ctor != null && !_isPublic(ctor)) continue;
      surface[ctor == null ? '$name.new' : '$name.$ctor'] =
          member.parameters.toSource();
    }
  }
}
