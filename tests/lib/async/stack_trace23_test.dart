// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/async_helper.dart';
import 'package:expect/expect.dart';
import 'dart:async';

StackTrace captureStackTrace() {
  try {
    throw 0;
  } catch (e, st) {
    return st;
  }
}

main() {
  StackTrace trace = captureStackTrace();
  asyncStart();
  var f = new Future.error(499, trace);
  f
      .catchError(
        (e) {
          throw "unreachable";
        },
        test: (e) {
          Expect.equals(499, e);
          return false;
        },
      )
      .catchError((e, st) {
        Expect.identical(trace, st);
        asyncEnd();
      }, test: (e) => e == 499);
}
