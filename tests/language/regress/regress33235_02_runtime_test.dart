// TODO(multitest): This was automatically migrated from a multitest and may
// contain strange or dead code.

// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Test for compliance with tables at
// https://github.com/dart-lang/sdk/issues/33235#issue-326617285
// Files 01 to 16 should be compile time errors, files 17 to 21 should not.

class C {
  static int n() {
    return 42;
  }
}

main() {
  print(C);
}
