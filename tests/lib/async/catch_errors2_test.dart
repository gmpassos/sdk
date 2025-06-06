// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:expect/async_helper.dart';
import 'package:expect/expect.dart';

import 'catch_errors.dart';

main() {
  asyncStart();
  bool futureWasExecuted = false;
  late Future done;

  // Error streams never close.
  catchErrors(() {
    done = new Future(() {
      futureWasExecuted = true;
    });
    return 'allDone';
  }).listen(
    (x) {
      Expect.fail("Unexpected callback");
    },
    onDone: () {
      Expect.fail("Unexpected callback");
    },
  );

  done.whenComplete(asyncEnd);
}
