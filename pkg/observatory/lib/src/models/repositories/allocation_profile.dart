// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file

part of models;

abstract class AllocationProfileRepository {
  Future<AllocationProfile> get(
    IsolateRef isolate, {
    bool gc = false,
    bool reset = false,
    bool combine = false,
  });
}
