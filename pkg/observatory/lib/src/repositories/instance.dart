// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file

part of repositories;

class InstanceRepository extends M.InstanceRepository {
  Future<M.Instance> get(
    M.IsolateRef i,
    String id, {
    int count = S.kDefaultFieldLimit,
  }) async {
    S.Isolate isolate = i as S.Isolate;
    return (await isolate.getObject(id, count: count)) as S.Instance;
  }
}
