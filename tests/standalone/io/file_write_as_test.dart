// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import "package:expect/async_helper.dart";
import "package:expect/expect.dart";

testWriteAsBytesSync(dir) {
  var f = new File('${dir.path}${Platform.pathSeparator}bytes_sync.txt');
  var data = [50, 50, 50];
  f.writeAsBytesSync(data);
  Expect.listEquals(data, f.readAsBytesSync());
  f.writeAsBytesSync(data, mode: FileMode.append, flush: true);
  var expected = [50, 50, 50, 50, 50, 50];
  Expect.listEquals(expected, f.readAsBytesSync());
}

void testWriteAsBytesOutsideOf0to256Sync(dir) {
  final f = new File(
    '${dir.path}${Platform.pathSeparator}outside_bytes_sync.txt',
  );
  final data = [-256, -255, -1, 0, 255, 256];

  f.writeAsBytesSync(data);
  final readData = f.readAsBytesSync();

  Expect.listEquals([0, 1, 255, 0, 255, 0], readData);
}

testWriteAsStringSync(dir) {
  var f = new File('${dir.path}${Platform.pathSeparator}string_sync.txt');
  var data = 'asdf';
  f.writeAsStringSync(data);
  Expect.equals(data, f.readAsStringSync());
  f.writeAsStringSync(data, mode: FileMode.append, flush: true);
  Expect.equals('$data$data', f.readAsStringSync());
}

void testWriteAsStringSyncLineEndings(Directory dir) {
  final f = new File('${dir.path}/eol.txt');
  f.writeAsStringSync('Hi\nLo', flush: true);
  final readBytes = f.readAsBytesSync();
  Expect.listEquals([72, 105, 10, 76, 111], readBytes);
}

testWriteWithLargeList(dir) {
  // 0x100000000 exceeds the maximum of unsigned long.
  // This should no longer hang.
  // Issue: https://github.com/dart-lang/sdk/issues/40339
  var bytes;
  try {
    bytes = Uint8List(0x100000000);
  } catch (e) {
    // Create a big Uint8List may lead to OOM. This is acceptable.
    Expect.isTrue(e.toString().contains('Out of Memory'));
    return;
  }
  if (Platform.isWindows) {
    File('\\\\?\\NUL').writeAsBytesSync(bytes);
  } else {
    File('/dev/null').writeAsBytesSync(bytes);
  }
}

Future testWriteAsBytes(dir) {
  var completer = new Completer();
  var f = new File('${dir.path}${Platform.pathSeparator}bytes.txt');
  var data = [50, 50, 50];
  f.writeAsBytes(data).then((file) {
    Expect.equals(f, file);
    f.readAsBytes().then((bytes) {
      Expect.listEquals(data, bytes);
      f.writeAsBytes(data, mode: FileMode.append, flush: true).then((file) {
        Expect.equals(f, file);
        f.readAsBytes().then((bytes) {
          var expected = [50, 50, 50, 50, 50, 50];
          Expect.listEquals(expected, bytes);
          completer.complete(true);
        });
      });
    });
  });
  return completer.future;
}

Future testWriteAsBytesOutsideOf0to256(dir) async {
  final f = new File('${dir.path}${Platform.pathSeparator}outside_bytes.txt');
  final data = [-256, -255, -1, 0, 255, 256];

  await f.writeAsBytes(data);
  final readData = await f.readAsBytes();

  Expect.listEquals([0, 1, 255, 0, 255, 0], readData);
}

Future testWriteAsString(dir) {
  var completer = new Completer();
  var f = new File('${dir.path}${Platform.pathSeparator}strings.txt');
  var data = 'asdf';
  f.writeAsString(data).then((file) {
    Expect.equals(f, file);
    f.readAsString().then((str) {
      Expect.equals(data, str);
      f.writeAsString(data, mode: FileMode.append, flush: true).then((file) {
        Expect.equals(f, file);
        f.readAsString().then((str) {
          Expect.equals('$data$data', str);
          completer.complete(true);
        });
      });
    });
  });
  return completer.future;
}

testWriteAsSubtypeSync(dir) {
  var f = new File('${dir.path}${Platform.pathSeparator}bytes_sync.txt');
  var input = Uint8List(5);
  input[0] = 1;
  input[1] = 2;
  f.writeAsBytesSync(input.asUnmodifiableView());
  var bytes = f.readAsBytesSync();
  Expect.listEquals(input, bytes);
}

class MyUint8List extends ListBase<int> implements List<int> {
  Uint8List _source;
  MyUint8List(this._source);

  // TypedData.
  ByteBuffer get buffer => _source.buffer;
  int get lengthInBytes => _source.lengthInBytes;
  int get offsetInBytes => _source.offsetInBytes;

  /// The methods that ListBase needs:
  int operator [](int index) => _source[index];
  operator []=(int index, int value) => _source[index] = value;
  int get length => _source.length;
  set length(_) => UnsupportedError("fixed length");
  int get elementSizeInBytes => _source.elementSizeInBytes;

  Uint8List sublist(int start, [int? end]) => _source.sublist(start, end);
}

void testCustomizedSubtypeSync(Directory dir) {
  var f = new File('${dir.path}${Platform.pathSeparator}bytes_sync.txt');
  var input = Uint8List(5);
  input[0] = 1;
  input[1] = 2;
  MyUint8List list = MyUint8List(input);
  f.writeAsBytesSync(list);
  var bytes = f.readAsBytesSync();
  Expect.listEquals(input, bytes);
}

main() async {
  asyncStart();
  var tempDir = Directory.systemTemp.createTempSync('dart_file_write_as');
  testWriteAsBytesSync(tempDir);
  testWriteAsBytesOutsideOf0to256Sync(tempDir);
  testWriteAsStringSync(tempDir);
  testWriteAsStringSyncLineEndings(tempDir);
  testWriteWithLargeList(tempDir);
  testWriteAsSubtypeSync(tempDir);
  testCustomizedSubtypeSync(tempDir);
  await testWriteAsBytes(tempDir);
  await testWriteAsBytesOutsideOf0to256(tempDir);
  await testWriteAsString(tempDir);
  tempDir.deleteSync(recursive: true);
  asyncEnd();
}
