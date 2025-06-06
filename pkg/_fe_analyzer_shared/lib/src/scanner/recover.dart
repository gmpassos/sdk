// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library _fe_analyzer_shared.scanner.recover;

String closeBraceFor(String openBrace) {
  return const {'(': ')', '[': ']', '{': '}', '<': '>', r'${': '}'}[openBrace]!;
}

String closeQuoteFor(String openQuote) {
  return const {
    '"': '"',
    "'": "'",
    '"""': '"""',
    "'''": "'''",
    'r"': '"',
    "r'": "'",
    'r"""': '"""',
    "r'''": "'''",
  }[openQuote]!;
}
