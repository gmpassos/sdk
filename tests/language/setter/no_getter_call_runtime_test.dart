// TODO(multitest): This was automatically migrated from a multitest and may
// contain strange or dead code.

// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/expect.dart";

var topLevelClosure;

get topLevel => topLevelClosure;

set topLevel(var value) {}

initialize() {
  print("initializing");
  topLevelClosure = (x) => x * 2;
}

main() {
  initialize();
  var x = topLevelClosure(2);
  Expect.equals(4, x);

  x = topLevel(3);
  Expect.equals(6, x);
}
