// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../common.dart';
import '../common/elements.dart' show CommonElements;
import '../common/names.dart' show Identifiers;
import '../elements/entities.dart';
import '../inferrer/types.dart' show GlobalTypeInferenceResults;
import '../js_model/elements.dart' show JFunction;
import '../kernel/no_such_method_resolver.dart';
import '../serialization/serialization.dart';

/// [NoSuchMethodRegistry] and [NoSuchMethodData] categorizes `noSuchMethod`
/// implementations.
///
/// If user code includes `noSuchMethod` implementations, type inference is
/// hindered because (for instance) any selector where the type of the
/// receiver is not known all implementations of `noSuchMethod` must be taken
/// into account when inferring the return type.
///
/// The situation can be ameliorated with some heuristics for disregarding some
/// `noSuchMethod` implementations during type inference. We can partition
/// `noSuchMethod` implementations into 4 categories.
///
/// Implementations in category A are the default implementations
/// `Object.noSuchMethod` and `Interceptor.noSuchMethod`.
///
/// Implementations in category B syntactically immediately throw, for example:
///
///     noSuchMethod(x) => throw 'not implemented'
///
/// Implementations that do not fall into category A or B are in category C.
/// They are the only category of implementation that are considered during type
/// inference.
///
/// Implementations that syntactically just forward to the super implementation,
/// for example:
///
///     noSuchMethod(x) => super.noSuchMethod(x);
///
/// are in the same category as the superclass implementation. This covers a
/// common case, where users implement `noSuchMethod` with these dummy
/// implementations to avoid warnings.

/// Registry for collecting `noSuchMethod` implementations and categorizing them
/// into categories `A`, `B`, `C`.
class NoSuchMethodRegistry {
  /// The implementations that fall into category A, described above.
  final Set<FunctionEntity> _defaultImpls = {};

  /// The implementations that fall into category B, described above.
  final Set<FunctionEntity> _throwingImpls = {};

  /// The implementations that fall into category C, described above.
  final Set<FunctionEntity> _otherImpls = {};

  /// The implementations that have not yet been categorized.
  final Set<FunctionEntity> _uncategorizedImpls = {};

  /// The implementations that a forwarding syntax as defined by
  /// [NoSuchMethodResolver.hasForwardSyntax].
  final Set<FunctionEntity> _forwardingSyntaxImpls = {};

  final CommonElements _commonElements;
  final NoSuchMethodResolver _resolver;

  NoSuchMethodRegistry(this._commonElements, this._resolver);

  NoSuchMethodResolver get internalResolverForTesting => _resolver;

  /// `true` if a category `B` method has been seen so far.
  bool get hasThrowingNoSuchMethod => _throwingImpls.isNotEmpty;

  /// `true` if a category `C` method has been seen so far.
  bool get hasComplexNoSuchMethod => _otherImpls.isNotEmpty;

  Iterable<FunctionEntity> get defaultImpls => _defaultImpls;

  Iterable<FunctionEntity> get throwingImpls => _throwingImpls;

  Iterable<FunctionEntity> get otherImpls => _otherImpls;

  /// Register [noSuchMethodElement].
  void registerNoSuchMethod(FunctionEntity noSuchMethodElement) {
    _uncategorizedImpls.add(noSuchMethodElement);
  }

  /// Categorizes the registered methods.
  void onQueueEmpty() {
    _uncategorizedImpls.forEach(_categorizeImpl);
    _uncategorizedImpls.clear();
  }

  NsmCategory _categorizeImpl(FunctionEntity element) {
    assert(element.name == Identifiers.noSuchMethod_);
    assert(!element.isAbstract);
    if (_defaultImpls.contains(element)) {
      return NsmCategory.default_;
    }
    if (_throwingImpls.contains(element)) {
      return NsmCategory.throwing;
    }
    if (_otherImpls.contains(element)) {
      return NsmCategory.other;
    }
    if (_commonElements.isDefaultNoSuchMethodImplementation(element)) {
      _defaultImpls.add(element);
      return NsmCategory.default_;
    } else if (_resolver.hasForwardingSyntax(element as JFunction)) {
      _forwardingSyntaxImpls.add(element);
      // If the implementation is 'noSuchMethod(x) => super.noSuchMethod(x);'
      // then it is in the same category as the super call.
      FunctionEntity superCall = _resolver.getSuperNoSuchMethod(element);
      NsmCategory category = _categorizeImpl(superCall);
      switch (category) {
        case NsmCategory.default_:
          _defaultImpls.add(element);
          break;
        case NsmCategory.throwing:
          _throwingImpls.add(element);
          break;
        case NsmCategory.other:
          _otherImpls.add(element);
          break;
      }
      return category;
    } else if (_resolver.hasThrowingSyntax(element)) {
      _throwingImpls.add(element);
      return NsmCategory.throwing;
    } else {
      _otherImpls.add(element);
      return NsmCategory.other;
    }
  }

  /// Closes the registry and returns data object used during type inference.
  NoSuchMethodData close() {
    return NoSuchMethodData(
      _throwingImpls,
      _otherImpls,
      _forwardingSyntaxImpls,
    );
  }
}

/// Data object used during type inference.
///
/// Post inference collected category `C` methods are into subcategories `C1`
/// and `C2`.
class NoSuchMethodData {
  /// Tag used for identifying serialized [NoSuchMethodData] objects in a
  /// debugging data stream.
  static const String tag = 'no-such-method-data';

  /// The implementations that fall into category B, described above.
  final Set<FunctionEntity> _throwingImpls;

  /// The implementations that fall into category C, described above.
  final Set<FunctionEntity> _otherImpls;

  /// The implementations that fall into category C1
  final Set<FunctionEntity> _complexNoReturnImpls = {};

  /// The implementations that fall into category C2
  final Set<FunctionEntity> _complexReturningImpls = {};

  final Set<FunctionEntity> _forwardingSyntaxImpls;

  NoSuchMethodData(
    this._throwingImpls,
    this._otherImpls,
    this._forwardingSyntaxImpls,
  );

  /// Deserializes a [NoSuchMethodData] object from [source].
  factory NoSuchMethodData.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    Set<FunctionEntity> throwingImpls = source
        .readMembers<FunctionEntity>()
        .toSet();
    Set<FunctionEntity> otherImpls = source
        .readMembers<FunctionEntity>()
        .toSet();
    Set<FunctionEntity> forwardingSyntaxImpls = source
        .readMembers<FunctionEntity>()
        .toSet();
    List<FunctionEntity> complexNoReturnImpls = source
        .readMembers<FunctionEntity>();
    List<FunctionEntity> complexReturningImpls = source
        .readMembers<FunctionEntity>();
    source.end(tag);
    return NoSuchMethodData(throwingImpls, otherImpls, forwardingSyntaxImpls)
      .._complexNoReturnImpls.addAll(complexNoReturnImpls)
      .._complexReturningImpls.addAll(complexReturningImpls);
  }

  /// Serializes this [NoSuchMethodData] to [sink].
  void writeToDataSink(DataSinkWriter sink) {
    sink.begin(tag);
    sink.writeMembers(_throwingImpls);
    sink.writeMembers(_otherImpls);
    sink.writeMembers(_forwardingSyntaxImpls);
    sink.writeMembers(_complexNoReturnImpls);
    sink.writeMembers(_complexReturningImpls);
    sink.end(tag);
  }

  Iterable<FunctionEntity> get throwingImpls => _throwingImpls;

  Iterable<FunctionEntity> get otherImpls => _otherImpls;

  Iterable<FunctionEntity> get forwardingSyntaxImpls => _forwardingSyntaxImpls;

  Iterable<FunctionEntity> get complexNoReturnImpls => _complexNoReturnImpls;

  Iterable<FunctionEntity> get complexReturningImpls => _complexReturningImpls;

  /// Now that type inference is complete, split category C into two
  /// subcategories: C1, those that have no return type, and C2, those
  /// that have a return type.
  void categorizeComplexImplementations(GlobalTypeInferenceResults results) {
    for (var element in _otherImpls) {
      if (results.resultOfMember(element).throwsAlways) {
        _complexNoReturnImpls.add(element);
      } else {
        _complexReturningImpls.add(element);
      }
    }
  }

  /// Emits a diagnostic about methods in categories `B`, `C1` and `C2`.
  void emitDiagnostic(DiagnosticReporter reporter) {
    for (var e in _throwingImpls) {
      if (!_forwardingSyntaxImpls.contains(e)) {
        reporter.reportHintMessage(e, MessageKind.directlyThrowingNsm);
      }
    }
    for (var e in _complexNoReturnImpls) {
      if (!_forwardingSyntaxImpls.contains(e)) {
        reporter.reportHintMessage(e, MessageKind.complexThrowingNsm);
      }
    }
    for (var e in _complexReturningImpls) {
      if (!_forwardingSyntaxImpls.contains(e)) {
        reporter.reportHintMessage(e, MessageKind.complexReturningNsm);
      }
    }
  }

  /// Returns [true] if the given element is a complex [noSuchMethod]
  /// implementation. An implementation is complex if it falls into
  /// category C, as described above.
  bool isComplex(FunctionEntity element) {
    assert(element.name == Identifiers.noSuchMethod_);
    return _otherImpls.contains(element);
  }
}

enum NsmCategory { default_, throwing, other }
