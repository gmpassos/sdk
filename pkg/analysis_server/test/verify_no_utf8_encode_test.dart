// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer_testing/package_root.dart';
import 'package:test/test.dart';

// TODO(scheglov): Remove it after SDK 3.1 published.
void main() {
  group('_fe_analyzer_shared', () {
    buildTests(packagePath: '_fe_analyzer_shared');
  });

  group('analyzer', () {
    buildTests(packagePath: 'analyzer');
  });
}

void buildTests({required String packagePath}) {
  var provider = PhysicalResourceProvider.INSTANCE;
  var pathContext = provider.pathContext;
  var pkgRootPath = pathContext.normalize(packageRoot);

  var libFolder = provider
      .getFolder(pkgRootPath)
      .getChildAssumingFolder(packagePath)
      .getChildAssumingFolder('lib');

  for (var file in libFolder.allFiles) {
    if (file_paths.isDart(pathContext, file.path)) {
      test(file.path, () {
        var content = file.readAsStringSync();
        if (content.contains('utf8.encode(')) {
          fail('Should not use `utf8.encode` before SDK 3.1');
        }
      });
    }
  }
}

extension on Folder {
  Iterable<File> get allFiles sync* {
    var queue = Queue<Folder>();
    queue.add(this);
    while (queue.isNotEmpty) {
      var current = queue.removeFirst();
      var children = current.getChildren();
      for (var child in children) {
        if (child is File) {
          yield child;
        } else if (child is Folder) {
          queue.add(child);
        }
      }
    }
  }
}
