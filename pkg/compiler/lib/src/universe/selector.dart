// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library;

import '../common.dart';
import '../common/names.dart' show Names;
import '../elements/entities.dart';
import '../elements/entity_utils.dart' as utils;
import '../elements/names.dart';
import '../elements/operators.dart';
import '../kernel/invocation_mirror.dart';
import '../serialization/serialization.dart';
import '../util/util.dart' show Hashing;
import 'call_structure.dart' show CallStructure;

enum SelectorKind {
  getter('getter'),
  setter('setter'),
  call('call'),
  operator('operator'),
  index_('index'),
  special('special');

  final String name;
  const SelectorKind(this.name);

  @override
  String toString() => name;
}

class Selector {
  /// Tag used for identifying serialized [Selector] objects in a debugging
  /// data stream.
  static const String tag = 'selector';

  final SelectorKind kind;
  final Name memberName;
  final CallStructure callStructure;

  @override
  final int hashCode;

  @override
  bool operator ==(other) => identical(this, other);

  int get argumentCount => callStructure.argumentCount;
  int get namedArgumentCount => callStructure.namedArgumentCount;
  int get positionalArgumentCount => callStructure.positionalArgumentCount;
  int get typeArgumentCount => callStructure.typeArgumentCount;
  List<String> get namedArguments => callStructure.namedArguments;

  String get name => memberName.text;

  static bool isOperatorName(String name) {
    return instanceMethodOperatorNames.contains(name);
  }

  Selector.internal(
    this.kind,
    this.memberName,
    this.callStructure,
    this.hashCode,
  ) {
    assert(
      kind == SelectorKind.index_ ||
          (memberName != Names.indexName && memberName != Names.indexSetName),
      failedAt(
        noLocationSpannable,
        "kind=$kind,memberName=$memberName,callStructure:$callStructure",
      ),
    );
    assert(
      kind == SelectorKind.operator ||
          kind == SelectorKind.index_ ||
          !isOperatorName(memberName.text) ||
          memberName.text == '??',
      failedAt(
        noLocationSpannable,
        "kind=$kind,memberName=$memberName,callStructure:$callStructure",
      ),
    );
    assert(
      kind == SelectorKind.call ||
          kind == SelectorKind.getter ||
          kind == SelectorKind.setter ||
          isOperatorName(memberName.text) ||
          memberName.text == '??',
      failedAt(
        noLocationSpannable,
        "kind=$kind,memberName=$memberName,callStructure:$callStructure",
      ),
    );
  }

  // TODO(johnniwinther): Extract caching.
  static Map<int, List<Selector>> canonicalizedValues = <int, List<Selector>>{};

  factory Selector(SelectorKind kind, Name name, CallStructure callStructure) {
    // TODO(johnniwinther): Maybe use equality instead of implicit hashing.
    int hashCode = computeHashCode(kind, name, callStructure);
    List<Selector> list = canonicalizedValues.putIfAbsent(hashCode, () => []);
    for (int i = 0; i < list.length; i++) {
      Selector existing = list[i];
      if (existing.match(kind, name, callStructure)) {
        assert(existing.hashCode == hashCode);
        return existing;
      }
    }
    Selector result = Selector.internal(kind, name, callStructure, hashCode);
    list.add(result);
    return result;
  }

  factory Selector.fromElement(MemberEntity element) {
    Name name = element.memberName;
    if (element.isFunction) {
      FunctionEntity function = element as FunctionEntity;
      if (name == Names.indexName) {
        return Selector.index();
      } else if (name == Names.indexSetName) {
        return Selector.indexSet();
      }
      CallStructure callStructure = function.parameterStructure.callStructure;
      if (isOperatorName(element.name!)) {
        // Operators cannot have named arguments, however, that doesn't prevent
        // a user from declaring such an operator.
        return Selector(SelectorKind.operator, name, callStructure);
      } else {
        return Selector.call(name, callStructure);
      }
    } else if (element.isSetter) {
      return Selector.setter(name);
    } else if (element.isGetter) {
      return Selector.getter(name);
    } else if (element is FieldEntity) {
      return Selector.getter(name);
    } else if (element is ConstructorEntity) {
      return Selector.callConstructor(name);
    } else {
      throw failedAt(element, "Cannot get selector from $element");
    }
  }

  factory Selector.getter(Name name) =>
      Selector(SelectorKind.getter, name.getter, CallStructure.noArgs);

  factory Selector.setter(Name name) =>
      Selector(SelectorKind.setter, name.setter, CallStructure.oneArg);

  factory Selector.unaryOperator(String name) => Selector(
    SelectorKind.operator,
    PublicName(utils.constructOperatorName(name, true)),
    CallStructure.noArgs,
  );

  factory Selector.binaryOperator(String name) => Selector(
    SelectorKind.operator,
    PublicName(utils.constructOperatorName(name, false)),
    CallStructure.oneArg,
  );

  factory Selector.index() =>
      Selector(SelectorKind.index_, Names.indexName, CallStructure.oneArg);

  factory Selector.indexSet() =>
      Selector(SelectorKind.index_, Names.indexSetName, CallStructure.twoArgs);

  factory Selector.call(Name name, CallStructure callStructure) =>
      Selector(SelectorKind.call, name, callStructure);

  factory Selector.callClosure(
    int arity, [
    List<String>? namedArguments,
    int typeArgumentCount = 0,
  ]) => Selector(
    SelectorKind.call,
    Names.call,
    CallStructure(arity, namedArguments, typeArgumentCount),
  );

  factory Selector.callClosureFrom(Selector selector) =>
      Selector(SelectorKind.call, Names.call, selector.callStructure);

  factory Selector.callConstructor(
    Name name, [
    int arity = 0,
    List<String>? namedArguments,
  ]) => Selector(SelectorKind.call, name, CallStructure(arity, namedArguments));

  factory Selector.callDefaultConstructor() =>
      Selector(SelectorKind.call, const PublicName(''), CallStructure.noArgs);

  // TODO(31953): Remove this if we can implement via static calls.
  factory Selector.genericInstantiation(int typeArguments) => Selector(
    SelectorKind.special,
    Names.genericInstantiation,
    CallStructure(0, null, typeArguments),
  );

  /// Deserializes a [Selector] object from [source].
  factory Selector.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    SelectorKind kind = source.readEnum(SelectorKind.values);
    Name memberName = source.readMemberName();
    CallStructure callStructure = CallStructure.readFromDataSource(source);
    source.end(tag);
    return Selector(kind, memberName, callStructure);
  }

  /// Serializes this [Selector] to [sink].
  void writeToDataSink(DataSinkWriter sink) {
    sink.begin(tag);
    sink.writeEnum(kind);
    sink.writeMemberName(memberName);
    callStructure.writeToDataSink(sink);
    sink.end(tag);
  }

  bool get isGetter => kind == SelectorKind.getter;
  bool get isSetter => kind == SelectorKind.setter;
  bool get isCall => kind == SelectorKind.call;

  /// Whether this selector might be invoking a closure. In some cases this
  /// selector is used to invoke a getter named 'call' and then invoke it. This
  /// can have different semantics than invoking a 'call' method.
  bool get isMaybeClosureCall => isCall && memberName == Names.callName;

  bool get isIndex => kind == SelectorKind.index_ && argumentCount == 1;
  bool get isIndexSet => kind == SelectorKind.index_ && argumentCount == 2;

  bool get isOperator => kind == SelectorKind.operator;
  bool get isUnaryOperator => isOperator && argumentCount == 0;

  /// The member name for invocation mirrors created from this selector.
  String get invocationMirrorMemberName => isSetter ? '$name=' : name;

  InvocationMirrorKind get invocationMirrorKind {
    var kind = InvocationMirrorKind.method;
    if (isGetter) {
      kind = InvocationMirrorKind.getter;
    } else if (isSetter) {
      kind = InvocationMirrorKind.setter;
    }
    return kind;
  }

  bool appliesUnnamed(MemberEntity element) {
    assert(name == element.name);
    if (!memberName.matches(element.memberName)) {
      return false;
    }
    return appliesStructural(element);
  }

  bool appliesStructural(MemberEntity element) {
    assert(name == element.name);
    if (element.isSetter) return isSetter;
    if (element.isGetter) return isGetter || isCall;
    if (element is FieldEntity) {
      return isSetter ? element.isAssignable : isGetter || isCall;
    }
    if (isGetter) return true;
    if (isSetter) return false;
    return signatureApplies(element as FunctionEntity);
  }

  /// Whether this [Selector] could be a valid selector on `Null` without
  /// throwing.
  bool appliesToNullWithoutThrow() {
    var name = this.name;
    if (isOperator && name == "==") return true;
    // Known getters and valid tear-offs.
    if (isGetter &&
        (name == "hashCode" ||
            name == "runtimeType" ||
            name == "toString" ||
            name == "noSuchMethod")) {
      return true;
    }
    // Calling toString always succeeds, calls to `noSuchMethod` (even well
    // formed calls) always throw.
    if (isCall &&
        name == "toString" &&
        positionalArgumentCount == 0 &&
        namedArgumentCount == 0) {
      return true;
    }
    return false;
  }

  bool signatureApplies(FunctionEntity function) {
    return callStructure.signatureApplies(function.parameterStructure);
  }

  bool applies(MemberEntity element) {
    if (name != element.name) return false;
    return appliesUnnamed(element);
  }

  bool match(SelectorKind kind, Name memberName, CallStructure callStructure) {
    return this.kind == kind &&
        this.memberName == memberName &&
        this.callStructure.match(callStructure);
  }

  static int computeHashCode(
    SelectorKind kind,
    Name name,
    CallStructure callStructure,
  ) {
    // Add bits from name and kind.
    int hash = Hashing.mixHashCodeBits(name.hashCode, kind.hashCode);
    // Add bits from the call structure.
    return Hashing.mixHashCodeBits(hash, callStructure.hashCode);
  }

  @override
  String toString() {
    return 'Selector($kind, $name, ${callStructure.structureToString()})';
  }

  /// Returns the normalized version of this selector.
  ///
  /// A selector is normalized if its call structure is normalized.
  // TODO(johnniwinther): Use normalized selectors as much as possible,
  // especially where selectors are used in sets or as keys in maps.
  Selector toNormalized() => callStructure.isNormalized
      ? this
      : Selector(kind, memberName, callStructure.toNormalized());

  Selector toCallSelector() => Selector.callClosureFrom(this);

  /// Returns the non-generic [Selector] corresponding to this selector.
  Selector toNonGeneric() {
    return callStructure.typeArgumentCount > 0
        ? Selector(kind, memberName, callStructure.nonGeneric)
        : this;
  }
}
