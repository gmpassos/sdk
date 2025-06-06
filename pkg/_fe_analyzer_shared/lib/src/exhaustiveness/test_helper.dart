// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/exhaustiveness/witness.dart';

import 'exhaustive.dart';
import 'key.dart';
import 'space.dart';
import 'static_type.dart';

/// Tags used for id-testing of exhaustiveness.
class Tags {
  static const String error = 'error';
  static const String scrutineeType = 'type';
  static const String scrutineeFields = 'fields';
  static const String space = 'space';
  static const String subtypes = 'subtypes';
  static const String expandedSubtypes = 'expandedSubtypes';
  static const String checkingOrder = 'checkingOrder';
}

/// Returns a textual representation for [space] used for testing.
String spacesToText(Space space) {
  String text = space.toString();
  if (text.startsWith('[') && (text.endsWith(']') || text.endsWith(']?'))) {
    // Avoid list-like syntax which collides with the [Features] encoding.
    return '<$text>';
  }
  return text;
}

/// Returns a textual representation for [fieldsOfInterest] used for testing.
String fieldsToText(
  StaticType type,
  ObjectPropertyLookup objectFieldLookup,
  Set<Key> fieldsOfInterest,
) {
  List<Key> sortedNames = fieldsOfInterest.toList()..sort();
  StringBuffer sb = new StringBuffer();
  String comma = '';
  sb.write('{');
  for (Key key in sortedNames) {
    sb.write(comma);
    if (key is ExtensionKey) {
      sb.write(key.receiverType);
      sb.write('.');
      sb.write(key.name);
      sb.write(':');
      sb.write(staticTypeToText(key.type));
    } else {
      StaticType? fieldType = type.getPropertyType(objectFieldLookup, key);
      sb.write(key.name);
      sb.write(':');
      if (fieldType != null) {
        sb.write(staticTypeToText(fieldType));
      } else {
        sb.write("-");
      }
    }
    comma = ',';
  }
  sb.write('}');
  return sb.toString();
}

/// Returns a textual representation for [type] used for testing.
String staticTypeToText(StaticType type) => type.toString();

/// Returns a textual representation of [types] used for testing.
String? typesToText(Iterable<StaticType> types) {
  if (types.isEmpty) return null;
  // TODO(johnniwinther): Sort types.
  StringBuffer sb = new StringBuffer();
  String comma = '';
  sb.write('{');
  for (StaticType subtype in types) {
    sb.write(comma);
    sb.write(staticTypeToText(subtype));
    comma = ',';
  }
  sb.write('}');
  return sb.toString();
}

String nonExhaustivenessToText(NonExhaustiveness nonExhaustiveness) {
  StringBuffer sb = new StringBuffer();
  sb.write('non-exhaustive:');
  String delimiter = '';
  for (Witness witness in nonExhaustiveness.witnesses) {
    sb.write(delimiter);
    String witnessText = witness.asWitness;
    String correctionText = witness.asCorrection;
    if (witnessText != correctionText) {
      sb.write('$witnessText/$correctionText');
    } else {
      sb.write(witnessText);
    }
    delimiter = ';';
  }
  return sb.toString();
}
