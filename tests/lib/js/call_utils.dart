// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:js/js.dart';

const dart2js = const bool.fromEnvironment('dart.library._dart2js_only');

@pragma('dart2js:noInline')
@pragma('dart2js:assumeDynamic')
dynamic confuse(dynamic x) => x;

@JS()
external dynamic eval(String script);

void injectJS() {
  eval('''
    self.jsFunction = function(s) {
        if (this == null) {
          throw "`this` is null or undefined";
        }
        if (typeof s != 'string') {
          throw "`s` is not a string";
        }
        return s.at(0);
      };
    self.jsObject = { call: function(s) {
        if (this == null) {
          throw "`this` is null or undefined";
        }
        if (typeof s != 'string') {
          throw "`s` is not a string";
        }
        return s.at(0);
      } };
    self.NamedClass = class NamedClass {
      call(s) {
        if (this == null) {
          throw "`this` is null or undefined";
        }
        if (typeof s != 'string') {
          throw "`s` is not a string";
        }
        return s.at(0);
      }
    }
    self.jsClass = new NamedClass();
    ''');
}

bool jsThisIsNullCheck(e) =>
    e.toString().contains('`this` is null or undefined');

bool jsArgIsNotStringCheck(e) => e.toString().contains('`s` is not a string');
