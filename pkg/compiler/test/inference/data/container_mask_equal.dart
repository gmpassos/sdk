// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Regression test for dart2js that used to have a bogus
// implementation of var.== and var.hashCode.

import 'dart:typed_data';

/*member: method1:Container([exact=JSExtendableArray|powerset={I}{G}{M}], element: [exact=JSUInt31|powerset={I}{O}{N}], length: 1, powerset: {I}{G}{M})*/
method1() => [0];

/*member: method2:Container([exact=JSExtendableArray|powerset={I}{G}{M}], element: [exact=JSUInt31|powerset={I}{O}{N}], length: 2, powerset: {I}{G}{M})*/
method2() => [1, 2];

/*member: method3:Container([exact=NativeUint8List|powerset={I}{O}{M}], element: [exact=JSUInt31|powerset={I}{O}{N}], length: 1, powerset: {I}{O}{M})*/
method3() => Uint8List(1);

/*member: method4:Container([exact=NativeUint8List|powerset={I}{O}{M}], element: [exact=JSUInt31|powerset={I}{O}{N}], length: 2, powerset: {I}{O}{M})*/
method4() => Uint8List(2);

/*member: method1or2:Container([exact=JSExtendableArray|powerset={I}{G}{M}], element: [exact=JSUInt31|powerset={I}{O}{N}], length: null, powerset: {I}{G}{M})*/
method1or2(/*[exact=JSBool|powerset={I}{O}{N}]*/ c) =>
    c ? method1() : method2();

/*member: method3or4:Container([exact=NativeUint8List|powerset={I}{O}{M}], element: [exact=JSUInt31|powerset={I}{O}{N}], length: null, powerset: {I}{O}{M})*/
method3or4(/*[exact=JSBool|powerset={I}{O}{N}]*/ c) =>
    c ? method3() : method4();

/*member: main:[null|powerset={null}]*/
main() {
  method1or2(true);
  method1or2(false);
  method3or4(true);
  method3or4(false);
}
