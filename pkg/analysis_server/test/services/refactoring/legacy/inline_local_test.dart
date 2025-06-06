// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/refactoring/legacy/inline_local.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' hide Element;
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'abstract_refactoring.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(InlineLocalTest);
  });
}

@reflectiveTest
class InlineLocalTest extends RefactoringTest {
  @override
  late InlineLocalRefactoringImpl refactoring;

  Future<void> test_access() async {
    await indexTestUnit('''
void f() {
  int test = 1 + 2;
  print(test);
  print(test);
}
''');
    _createRefactoring('test =');
    expect(refactoring.refactoringName, 'Inline Local Variable');
    // check initial conditions and access
    await refactoring.checkInitialConditions();
    expect(refactoring.variableName, 'test');
    expect(refactoring.referenceCount, 2);
  }

  Future<void> test_bad_selectionMethod() async {
    await indexTestUnit(r'''
void f() {
}
''');
    _createRefactoring('f() {');
    var status = await refactoring.checkInitialConditions();
    _assert_fatalError_selection(status);
  }

  Future<void> test_bad_selectionParameter() async {
    await indexTestUnit(r'''
void f(int test) {
}
''');
    _createRefactoring('test) {');
    var status = await refactoring.checkInitialConditions();
    _assert_fatalError_selection(status);
  }

  Future<void> test_bad_selectionVariable_hasAssignments_1() async {
    await indexTestUnit(r'''
void f() {
  int test = 0;
  test = 1;
}
''');
    _createRefactoring('test = 0');
    var status = await refactoring.checkInitialConditions();
    assertRefactoringStatus(
      status,
      RefactoringProblemSeverity.FATAL,
      expectedContextSearch: 'test = 1',
    );
  }

  Future<void> test_bad_selectionVariable_hasAssignments_2() async {
    await indexTestUnit(r'''
void f() {
  int test = 0;
  test += 1;
}
''');
    _createRefactoring('test = 0');
    var status = await refactoring.checkInitialConditions();
    assertRefactoringStatus(
      status,
      RefactoringProblemSeverity.FATAL,
      expectedContextSearch: 'test += 1',
    );
  }

  Future<void> test_bad_selectionVariable_notInBlock() async {
    await indexTestUnit(r'''
void f() {
  if (true)
    int test = 0;
}
''');
    _createRefactoring('test = 0');
    var status = await refactoring.checkInitialConditions();
    assertRefactoringStatus(status, RefactoringProblemSeverity.FATAL);
  }

  Future<void> test_bad_selectionVariable_notInitialized() async {
    await indexTestUnit(r'''
void f() {
  int test;
}
''');
    _createRefactoring('test;');
    var status = await refactoring.checkInitialConditions();
    assertRefactoringStatus(status, RefactoringProblemSeverity.FATAL);
  }

  Future<void> test_OK_cascade_intoCascade() async {
    await indexTestUnit(r'''
class A {
  foo() {}
  bar() {}
}
void f() {
  A test = new A()..foo();
  test..bar();
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring(r'''
class A {
  foo() {}
  bar() {}
}
void f() {
  new A()..foo()..bar();
}
''');
  }

  Future<void> test_OK_cascade_intoNotCascade() async {
    await indexTestUnit(r'''
class A {
  foo() {}
  bar() {}
}
void f() {
  A test = new A()..foo();
  test.bar();
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring(r'''
class A {
  foo() {}
  bar() {}
}
void f() {
  (new A()..foo()).bar();
}
''');
  }

  Future<void> test_OK_inSwitchCase_language219() async {
    await indexTestUnit('''
// @dart=2.19
void f(int p) {
  switch (p) {
    case 0:
      int test = 42;
      print(test);
      break;
  }
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
// @dart=2.19
void f(int p) {
  switch (p) {
    case 0:
      print(42);
      break;
  }
}
''');
  }

  Future<void> test_OK_inSwitchPatternCase() async {
    await indexTestUnit('''
void f(Object? x) {
  switch (x) {
    case _?:
      var test = 42;
      print(test);
  }
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f(Object? x) {
  switch (x) {
    case _?:
      print(42);
  }
}
''');
  }

  /// Check when inlining a static member access into a switch pattern it
  /// doesn't add unnecessary parens.
  Future<void> test_OK_inSwitchPatternCase_staticMember() async {
    await indexTestUnit('''
class C {
  static final i = 5;
}

void f() {
  final v = C.i;
  var _ = switch (v) {
    _ => 1,
  };
}
''');
    _createRefactoring('v =');
    // validate change
    await assertSuccessfulRefactoring('''
class C {
  static final i = 5;
}

void f() {
  var _ = switch (C.i) {
    _ => 1,
  };
}
''');
  }

  Future<void> test_OK_intoStringInterpolation_binaryExpression() async {
    await indexTestUnit(r'''
void f() {
  int test = 1 + 2;
  print('test = $test');
  print('test = ${test}');
  print('test = ${process(test)}');
}
process(x) {}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  print('test = ${1 + 2}');
  print('test = ${1 + 2}');
  print('test = ${process(1 + 2)}');
}
process(x) {}
''');
  }

  Future<void> test_OK_intoStringInterpolation_simpleIdentifier() async {
    await indexTestUnit(r'''
void f() {
  int foo = 1 + 2;
  int test = foo;
  print('test = $test');
  print('test = ${test}');
  print('test = ${process(test)}');
}
process(x) {}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  int foo = 1 + 2;
  print('test = $foo');
  print('test = ${foo}');
  print('test = ${process(foo)}');
}
process(x) {}
''');
  }

  Future<void> test_OK_intoStringInterpolation_string_differentQuotes() async {
    await indexTestUnit(r'''
void f() {
  String a = "aaa";
  String b = '$a bbb';
}
''');
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  String b = '${"aaa"} bbb';
}
''');
  }

  Future<void> test_OK_intoStringInterpolation_string_doubleQuotes() async {
    await indexTestUnit(r'''
void f() {
  String a = "aaa";
  String b = "$a bbb";
}
''');
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  String b = "aaa bbb";
}
''');
  }

  Future<void>
  test_OK_intoStringInterpolation_string_multiLineIntoMulti_leadingSpaces() async {
    await indexTestUnit(r"""
void f() {
  String a = '''\ \
a
a''';
  String b = '''
$a
bbb''';
}
""");
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r"""
void f() {
  String b = '''
a
a
bbb''';
}
""");
  }

  Future<void>
  test_OK_intoStringInterpolation_string_multiLineIntoMulti_unixEOL() async {
    await indexTestUnit(r"""
void f() {
  String a = '''
a
a
a''';
  String b = '''
$a
bbb''';
}
""");
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r"""
void f() {
  String b = '''
a
a
a
bbb''';
}
""");
  }

  Future<void>
  test_OK_intoStringInterpolation_string_multiLineIntoMulti_windowsEOL() async {
    await indexTestUnit(
      r"""
void f() {
  String a = '''
a
a
a''';
  String b = '''
$a
bbb''';
}
""".replaceAll('\n', '\r\n'),
    );
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(
      r"""
void f() {
  String b = '''
a
a
a
bbb''';
}
""".replaceAll('\n', '\r\n'),
    );
  }

  Future<void>
  test_OK_intoStringInterpolation_string_multiLineIntoSingle() async {
    await indexTestUnit(r'''
void f() {
  String a = """aaa""";
  String b = "$a bbb";
}
''');
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  String b = "${"""aaa"""} bbb";
}
''');
  }

  Future<void> test_OK_intoStringInterpolation_string_raw() async {
    await indexTestUnit(r'''
void f() {
  String a = r'an $ignored interpolation';
  String b = '$a bbb';
}
''');
    _createRefactoring('a =');
    // we don't unwrap raw strings
    await assertSuccessfulRefactoring(r'''
void f() {
  String b = '${r'an $ignored interpolation'} bbb';
}
''');
  }

  Future<void>
  test_OK_intoStringInterpolation_string_singleLineIntoMulti_doubleQuotes() async {
    await indexTestUnit(r'''
void f() {
  String a = "aaa";
  String b = """$a bbb""";
}
''');
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  String b = """aaa bbb""";
}
''');
  }

  Future<void>
  test_OK_intoStringInterpolation_string_singleLineIntoMulti_singleQuotes() async {
    await indexTestUnit(r"""
void f() {
  String a = 'aaa';
  String b = '''$a bbb''';
}
""");
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r"""
void f() {
  String b = '''aaa bbb''';
}
""");
  }

  Future<void> test_OK_intoStringInterpolation_string_singleQuotes() async {
    await indexTestUnit(r'''
void f() {
  String a = 'aaa';
  String b = '$a bbb';
}
''');
    _createRefactoring('a =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  String b = 'aaa bbb';
}
''');
  }

  Future<void> test_OK_intoStringInterpolation_stringInterpolation() async {
    await indexTestUnit(r'''
void f() {
  String a = 'aaa';
  String b = '$a bbb';
  String c = '$b ccc';
}
''');
    _createRefactoring('b =');
    // validate change
    await assertSuccessfulRefactoring(r'''
void f() {
  String a = 'aaa';
  String c = '$a bbb ccc';
}
''');
  }

  /// https://code.google.com/p/dart/issues/detail?id=18587
  Future<void> test_OK_keepNextCommentedLine() async {
    await indexTestUnit('''
void f() {
  int test = 1 + 2;
  // foo
  print(test);
  // bar
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  // foo
  print(1 + 2);
  // bar
}
''');
  }

  Future<void> test_OK_listLiteral() async {
    await indexTestUnit('''
void f() {
  var test = 42.isEven;
  [0, test, 1];
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  [0, 42.isEven, 1];
}
''');
  }

  Future<void> test_OK_mapLiteral1() async {
    await indexTestUnit('''
void f() {
  var test = 42.isEven;
  <dynamic, dynamic>{0: test};
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  <dynamic, dynamic>{0: 42.isEven};
}
''');
  }

  Future<void> test_OK_mapLiteral2() async {
    await indexTestUnit('''
void f() {
  var test = 42.isEven;
  <dynamic, dynamic>{test: 1};
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  <dynamic, dynamic>{42.isEven: 1};
}
''');
  }

  Future<void> test_OK_noUsages_1() async {
    await indexTestUnit('''
void f() {
  int test = 1 + 2;
  print(0);
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  print(0);
}
''');
  }

  Future<void> test_OK_noUsages_2() async {
    await indexTestUnit('''
void f() {
  int test = 1 + 2;
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
}
''');
  }

  Future<void> test_OK_oneUsage() async {
    await indexTestUnit('''
void f() {
  int test = 1 + 2;
  print(test);
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  print(1 + 2);
}
''');
  }

  Future<void> test_OK_parenthesis_decrement_intoNegate() async {
    await indexTestUnit('''
void f() {
  var a = 1;
  var test = --a;
  var b = -test;
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  var a = 1;
  var b = -(--a);
}
''');
  }

  Future<void> test_OK_parenthesis_instanceCreation_intoList() async {
    await indexTestUnit('''
class A {}
void f() {
  var test = new A();
  var list = [test];
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
class A {}
void f() {
  var list = [new A()];
}
''');
  }

  Future<void> test_OK_parenthesis_intoIndexExpression_index() async {
    await indexTestUnit('''
void f() {
  var items = [];
  var test = 1 + 2;
  items[test] * 5;
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  var items = [];
  items[1 + 2] * 5;
}
''');
  }

  Future<void> test_OK_parenthesis_intoParenthesizedExpression() async {
    await indexTestUnit('''
f(m, x, y) {
  int test = x as int;
  m[test] = y;
  return m[test];
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
f(m, x, y) {
  m[x as int] = y;
  return m[x as int];
}
''');
  }

  Future<void> test_OK_parenthesis_negate_intoNegate() async {
    await indexTestUnit('''
void f() {
  var a = 1;
  var test = -a;
  var b = -test;
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  var a = 1;
  var b = -(-a);
}
''');
  }

  Future<void> test_OK_parenthesis_plus_intoMultiply() async {
    await indexTestUnit('''
void f() {
  var test = 1 + 2;
  print(test * 3);
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  print((1 + 2) * 3);
}
''');
  }

  Future<void> test_OK_recordLiteral() async {
    await indexTestUnit('''
void f() {
  var test = 42.isEven;
  (0, test, 1);
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  (0, 42.isEven, 1);
}
''');
  }

  Future<void> test_OK_setLiteral() async {
    await indexTestUnit('''
void f() {
  var test = 42.isEven;
  <dynamic>{0, test, 1};
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  <dynamic>{0, 42.isEven, 1};
}
''');
  }

  Future<void> test_OK_twoUsages() async {
    await indexTestUnit('''
void f() {
  int test = 1 + 2;
  print(test);
  print(test);
}
''');
    _createRefactoring('test =');
    // validate change
    await assertSuccessfulRefactoring('''
void f() {
  print(1 + 2);
  print(1 + 2);
}
''');
  }

  void _assert_fatalError_selection(RefactoringStatus status) {
    expect(refactoring.variableName, isNull);
    expect(refactoring.referenceCount, 0);
    assertRefactoringStatus(
      status,
      RefactoringProblemSeverity.FATAL,
      expectedMessage:
          'Local variable declaration or reference must be '
          'selected to activate this refactoring.',
    );
  }

  void _createRefactoring(String search) {
    var offset = findOffset(search);
    refactoring = InlineLocalRefactoringImpl(
      searchEngine,
      testAnalysisResult,
      offset,
    );
  }
}
