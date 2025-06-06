// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Lib3Class {}

void lib3Method() {}

int? lib3Field;

extension type Lib3ExtType(int raw) {}

extension Lib3Ext on int {
  bool get lib3IsPositive => this > 0;
}
