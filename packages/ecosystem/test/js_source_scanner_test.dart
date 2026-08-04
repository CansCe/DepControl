import 'package:ecosystem/ecosystem.dart';
import 'package:test/test.dart';

void main() {
  const scanner = JsSourceScanner();

  Set<String> scan(String source) => scanner.scan([source]);

  group('the ways an import is written', () {
    test('named, default and namespace imports', () {
      expect(scan("import lodash from 'lodash';"), {'lodash'});
      expect(scan("import { debounce } from 'lodash';"), {'lodash'});
      expect(scan("import * as _ from 'lodash';"), {'lodash'});
      expect(scan("import lodash, { debounce } from 'lodash';"), {'lodash'});
    });

    test('a side-effect import with no bindings', () {
      expect(scan("import 'zone.js';"), {'zone.js'});
    });

    test('re-exports', () {
      expect(scan("export { x } from 'lodash';"), {'lodash'});
      expect(scan("export * from 'lodash';"), {'lodash'});
    });

    test('require and dynamic import', () {
      expect(scan("const _ = require('lodash');"), {'lodash'});
      expect(scan("const m = await import('lodash');"), {'lodash'});
    });

    test('double and single quotes alike', () {
      expect(scan('import x from "lodash";'), {'lodash'});
    });

    test('a triple-slash type reference names an @types package', () {
      // `types="node"` is not a module specifier. It names `@types/node`,
      // which is how a project depends on type declarations without importing
      // anything from them. Reading it as a specifier would report a
      // dependency on a package called `node` — and one is published.
      expect(scan('/// <reference types="node" />'), {'@types/node'});
      expect(scan('/// <reference types="jest" />'), {'@types/jest'});
    });

    test('several imports across one file', () {
      expect(
        scan('''
import React from 'react';
import { render } from 'react-dom';
const fs = require('fs');
'''),
        {'react', 'react-dom'},
      );
    });
  });

  group('what is not a package', () {
    test('relative and absolute paths', () {
      expect(scan("import x from './util';"), isEmpty);
      expect(scan("import x from '../lib/x';"), isEmpty);
      expect(scan("import x from '/etc/thing';"), isEmpty);
    });

    test('node builtins, prefixed or not', () {
      // `path`, `crypto`, `util`, `events` and `stream` are all also real npm
      // packages. Reporting an import of the builtin as a dependency would put
      // another author's advisories on this project's report.
      expect(scan("import fs from 'fs';"), isEmpty);
      expect(scan("import path from 'path';"), isEmpty);
      expect(scan("import crypto from 'crypto';"), isEmpty);
      expect(scan("import fs from 'node:fs/promises';"), isEmpty);
    });

    test('a URL import', () {
      expect(scan("import x from 'https://esm.sh/lodash';"), isEmpty);
    });

    test('a bare scope is not a complete name', () {
      expect(scan("import x from '@types';"), isEmpty);
    });
  });

  group('subpaths and scopes', () {
    test('a subpath belongs to its package', () {
      expect(scan("import fp from 'lodash/fp';"), {'lodash'});
      expect(scan("import x from 'date-fns/locale/en-US';"), {'date-fns'});
    });

    test('a scoped package keeps both segments', () {
      expect(scan("import type { X } from '@types/node';"), {'@types/node'});
      expect(scan("import x from '@babel/core/lib/thing';"), {'@babel/core'});
    });
  });

  group('comments', () {
    test('an example import in a block comment is not one', () {
      expect(
        scan('''
/**
 * Usage:
 *   import thing from 'not-a-real-dependency';
 */
import real from 'lodash';
'''),
        {'lodash'},
      );
    });

    test('a commented-out import is not one', () {
      expect(
        scan('''
// import old from 'removed-package';
import real from 'lodash';
'''),
        {'lodash'},
      );
    });

    test('a url in a comment does not break the line stripper', () {
      expect(
        scan('''
// see https://example.com/docs
import real from 'lodash';
'''),
        {'lodash'},
      );
    });
  });

  group('packageOf', () {
    test('reduces a specifier to the package it names', () {
      expect(JsSourceScanner.packageOf('lodash/fp'), 'lodash');
      expect(JsSourceScanner.packageOf('@scope/pkg/sub'), '@scope/pkg');
      expect(JsSourceScanner.packageOf('./local'), isNull);
      expect(JsSourceScanner.packageOf('node:fs'), isNull);
      expect(JsSourceScanner.packageOf(''), isNull);
    });
  });

  test('scanning nothing finds nothing, and says so by being empty', () {
    // Distinct from never having scanned, which the caller represents as null.
    expect(scanner.scan(const []), isEmpty);
  });
}
