// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/error/codes.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/context_collection_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(DuplicateRestElementInPatternTest);
  });
}

@reflectiveTest
class DuplicateRestElementInPatternTest extends PubPackageResolutionTest {
  test_listPattern() async {
    await assertErrorsInCode(
      r'''
void f(List<int> x) {
  if (x case [..., ...]) {}
}
''',
      [
        error(
          CompileTimeErrorCode.DUPLICATE_REST_ELEMENT_IN_PATTERN,
          41,
          3,
          contextMessages: [message(testFile, 36, 3)],
        ),
      ],
    );
    var node = findNode.singleGuardedPattern.pattern;
    assertResolvedNodeText(node, r'''
ListPattern
  leftBracket: [
  elements
    RestPatternElement
      operator: ...
    RestPatternElement
      operator: ...
  rightBracket: ]
  matchedValueType: List<int>
  requiredType: List<int>
''');
  }
}
