// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/utilities/package_config_file_builder.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../rule_test_support.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PreferRelativeImportsTest);
  });
}

@reflectiveTest
class PreferRelativeImportsTest extends LintRuleTest {
  @override
  bool get addJsPackageDep => true;

  @override
  String get lintRule => LintNames.prefer_relative_imports;

  test_externalPackage() async {
    await assertNoDiagnostics(r'''
/// This provides [JS].
import 'package:js/js.dart';
''');
  }

  test_internalPackage() async {
    var packageConfigBuilder = PackageConfigFileBuilder();
    packageConfigBuilder.add(
      name: 'internal_package',
      rootPath: '$testPackageRootPath/vendor/internal_package',
    );
    writeTestPackageConfig(packageConfigBuilder);

    newFile('$testPackageRootPath/vendor/internal_package/lib/lib.dart', r'''
class C {}
''');
    await assertNoDiagnostics(r'''
/// This provides [C].
import 'package:internal_package/lib.dart';
''');
  }

  test_samePackage_packageSchema() async {
    newFile('$testPackageLibPath/lib.dart', r'''
class C {}
''');
    await assertDiagnostics(
      r'''
/// This provides [C].
import 'package:test/lib.dart';
''',
      [lint(30, 23)],
    );
  }

  test_samePackage_packageSchema_fromOutsideLib() async {
    newFile('$testPackageLibPath/lib.dart', r'''
class C {}
''');
    var bin = newFile('$testPackageRootPath/bin/bin.dart', r'''
/// This provides [C].
import 'package:test/lib.dart';
''');
    await assertNoDiagnosticsInFile(bin.path);
  }

  test_samePackage_packageSchema_inPart() async {
    newFile('$testPackageLibPath/lib.dart', r'''
class C {}
''');

    newFile('$testPackageRootPath/test/a.dart', r'''
part 'test.dart';
''');

    await assertDiagnostics(
      r'''
part of 'a.dart';

/// This provides [C].
import 'package:test/lib.dart';
''',
      [lint(49, 23)],
    );
  }

  test_samePackage_relativeUri() async {
    newFile('$testPackageLibPath/lib.dart', r'''
class C {}
''');
    await assertNoDiagnostics(r'''
/// This provides [C].
import 'lib.dart';
''');
  }
}
