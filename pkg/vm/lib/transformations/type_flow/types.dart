// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Declares the type system used by global type flow analysis.
library;

import 'dart:core' hide Type;

import 'package:collection/collection.dart';
import 'package:kernel/ast.dart' hide Variance;
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart' show getFreshTypeParameters;
import 'package:kernel/target/targets.dart' show Target;

import 'utils.dart';

/// Class representation used in the type flow analysis.
///
/// For each ordinary Dart class there is a unique instance of [TFClass].
///
/// There are distinct [TFClass] objects for each record shape.
/// They may map to the same or distinct implementation Dart classes
/// depending on the [Target.getRecordImplementationClass].
///
/// Each [TFClass] has unique id which could be used to sort classes.
class TFClass {
  final int id;
  final Class classNode;
  final Set<TFClass> supertypes; // List of super-types including this.
  final RecordShape? recordShape;
  final Map<TypeAttributes, ConcreteType> _concreteTypesWithAttributes = {};

  /// TFClass should not be instantiated directly.
  /// Instead, [TypeHierarchy.getTFClass] should be used to obtain [TFClass]
  /// instances specific to given [TypeHierarchy].
  TFClass(this.id, this.classNode, this.supertypes, this.recordShape) {
    supertypes.add(this);
  }

  /// Returns ConcreteType corresponding to this class without
  /// any extra attributes.
  late final ConcreteType concreteType = ConcreteType._(this, null, null);

  /// Returns ConcreteType corresponding to this class and
  /// [constant] value.
  ConcreteType constantConcreteType(Constant constant) =>
      _concreteTypeWithAttributes(
        TypeAttributes._(constant, _closureForConstant(constant)),
      );

  /// Returns ConcreteType corresponding to this class and
  /// given [function] in [member].
  ConcreteType closureConcreteType(Member member, LocalFunction? function) {
    assert(
      function != null ||
          (member is Procedure &&
              !member.isGetter &&
              !member.isSetter &&
              !member.isStatic &&
              !member.isAbstract),
    );
    return _concreteTypeWithAttributes(
      TypeAttributes._(null, Closure(member, function)),
    );
  }

  /// Returns ConeType corresponding to this class.
  late final ConeType coneType = ConeType._(this);

  bool get isRecord => recordShape != null;

  /// Tests if [this] is a subtype of [other].
  bool isSubtypeOf(TFClass other) {
    final result = identical(this, other) || supertypes.contains(other);
    if (kPrintTrace) {
      tracePrint("isSubtype sub $this, sup $other = $result");
    }
    return result;
  }

  bool get hasDynamicallyExtendableSubtypes => false;

  @override
  int get hashCode => id;

  @override
  bool operator ==(other) => identical(this, other);

  @override
  String toString() =>
      isRecord
          ? '${nodeToText(classNode)}[$recordShape]'
          : nodeToText(classNode);

  ConcreteType _concreteTypeWithAttributes(TypeAttributes attr) =>
      _concreteTypesWithAttributes[attr] ??= ConcreteType._(this, null, attr);

  Closure? _closureForConstant(Constant c) {
    if (c is InstantiationConstant) {
      return _closureForConstant(c.tearOffConstant);
    } else if (c is TearOffConstant) {
      final target = c.target;
      assert(
        target is Constructor ||
            (target is Procedure &&
                target.isStatic &&
                !target.isGetter &&
                !target.isSetter),
      );
      return Closure(target, null);
    } else if (c is TypedefTearOffConstant) {
      throw 'Unexpected TypedefTearOffConstant $c';
    }
    return null;
  }
}

/// Shape of a record (number of positional fields and a set of named fields).
class RecordShape {
  final int numPositionalFields;
  final List<String> namedFields; // Sorted.
  final int _hash = 0;

  RecordShape(RecordType type)
    : numPositionalFields = type.positional.length,
      namedFields =
          type.named.isEmpty
              ? const <String>[]
              : type.named.map((nt) => nt.name).toList(growable: false);

  int get numFields => numPositionalFields + namedFields.length;

  String fieldName(int i) {
    if (i < numPositionalFields) {
      return "\$${i + 1}";
    } else {
      return namedFields[i - numPositionalFields];
    }
  }

  RecordShape.readFromBinary(BinarySource source)
    : numPositionalFields = source.readUInt30(),
      namedFields = List<String>.generate(
        source.readUInt30(),
        (_) => source.readStringReference(),
        growable: false,
      );

  void writeToBinary(BinarySink sink) {
    sink.writeUInt30(numPositionalFields);
    sink.writeUInt30(namedFields.length);
    for (int i = 0; i < namedFields.length; ++i) {
      sink.writeStringReference(namedFields[i]);
    }
  }

  @override
  int get hashCode => (_hash == 0) ? _computeHashCode() : _hash;

  int _computeHashCode() {
    int hash = combineHashes(numPositionalFields, listHashCode(namedFields));
    if (hash == 0) {
      hash = 1;
    }
    return hash;
  }

  @override
  bool operator ==(other) =>
      identical(this, other) ||
      (other is RecordShape &&
          this.numPositionalFields == other.numPositionalFields &&
          listEquals(this.namedFields, other.namedFields));

  @override
  String toString() =>
      namedFields.isEmpty
          ? '$numPositionalFields'
          : '$numPositionalFields,${namedFields.join(',')}';
}

abstract class GenericInterfacesInfo {
  // Return a type arguments vector which contains the immediate type parameters
  // to 'klass' as well as the type arguments to all generic supertypes of
  // 'klass', instantiated in terms of the type parameters on 'klass'.
  //
  // The offset into this vector from which a specific generic supertype's type
  // arguments can be found is given by 'genericInterfaceOffsetFor'.
  List<DartType> flattenedTypeArgumentsFor(Class klass);

  // Return the offset into the flattened type arguments vector from which a
  // specific generic supertype's type arguments can be found. The flattened
  // type arguments vector is given by 'flattenedTypeArgumentsFor'.
  int genericInterfaceOffsetFor(Class klass, Class iface);

  // Similar to 'flattenedTypeArgumentsFor', but works for non-generic classes
  // which may have recursive substitutions, e.g. 'class num implements
  // Comparable<num>'.
  //
  // Since there are no free type variables in the result, 'RuntimeType' is
  // returned instead of 'DartType'.
  List<Type> flattenedTypeArgumentsForNonGeneric(Class klass);
}

abstract class TypesBuilder {
  final CoreTypes coreTypes;
  final Target target;

  TypesBuilder(this.coreTypes, this.target);

  /// Return [TFClass] corresponding to the given [classNode].
  TFClass getTFClass(Class classNode);

  /// Return [Type] corresponding to the given record shape.
  /// [allocated] flag indicates that an instance of
  /// this record shape is allocated.
  Type getRecordType(RecordShape shape, bool allocated) =>
      getTFClass(coreTypes.recordClass).coneType;

  late final Type functionType = getTFClass(coreTypes.functionClass).coneType;

  late final ConcreteType boolType =
      getTFClass(coreTypes.boolClass).concreteType;

  late final ConcreteType constantTrue = boolType.cls.constantConcreteType(
    BoolConstant(true),
  );

  late final ConcreteType constantFalse = boolType.cls.constantConcreteType(
    BoolConstant(false),
  );

  /// Create a Type which corresponds to a set of instances constrained by
  /// Dart type annotation [dartType].
  /// [canBeNull] can be set to false to further constrain the resulting
  /// type if value cannot be null.
  Type fromStaticType(DartType type, bool canBeNull) {
    Type result;
    if (type is InterfaceType) {
      final cls = type.classNode;
      result = getTFClass(cls).coneType;
    } else if (type == const DynamicType() || type == const VoidType()) {
      result = anyInstanceType;
    } else if (type is NeverType || type is NullType) {
      result = emptyType;
    } else if (type is FunctionType) {
      result = functionType;
    } else if (type is RecordType) {
      result = getRecordType(RecordShape(type), false);
    } else if (type is FutureOrType) {
      // TODO(alexmarkov): support FutureOr types
      result = anyInstanceType;
    } else if (type is TypeParameterType) {
      final bound = type.bound;
      // Protect against infinite recursion in case of cyclic type parameters
      // like 'T extends T'. As of today, front-end doesn't report errors in such
      // cases yet.
      if (bound is TypeParameterType) {
        result = anyInstanceType;
      } else {
        result = fromStaticType(bound, canBeNull);
      }
    } else if (type is IntersectionType) {
      final bound = type.right;
      if (bound is TypeParameterType) {
        result = anyInstanceType;
      } else {
        result = fromStaticType(bound, canBeNull);
      }
    } else if (type is ExtensionType) {
      result = fromStaticType(type.extensionTypeErasure, canBeNull);
    } else {
      throw 'Unexpected type ${type.runtimeType} $type';
    }
    if (type.nullability == Nullability.nonNullable) {
      canBeNull = false;
    }
    if (canBeNull) {
      result = result.nullable();
    }
    return result;
  }
}

abstract class RuntimeTypeTranslator {
  TypeExpr instantiateConcreteType(ConcreteType type, List<DartType> typeArgs);
}

/// Abstract interface to type hierarchy information used by types.
abstract class TypeHierarchy extends TypesBuilder
    implements GenericInterfacesInfo {
  TypeHierarchy(CoreTypes coreTypes, Target target) : super(coreTypes, target);

  /// Test if [sub] is a subtype of [sup].
  bool isSubtype(Class sub, Class sup) {
    return identical(sub, sup) || getTFClass(sub).isSubtypeOf(getTFClass(sup));
  }

  /// Return a more specific type for the type cone with [base] root.
  /// May return EmptyType, AnyInstanceType, WideConeType, ConcreteType or a SetType.
  /// WideConeType can be returned only if [allowWideCone].
  ///
  /// This method is used when calculating type flow throughout the program.
  /// It is correct (although less accurate) for [specializeTypeCone] to return
  /// a larger set. In such case analysis would admit that a larger set of
  /// values can flow through the program.
  Type specializeTypeCone(TFClass base, {required bool allowWideCone});

  /// Returns true if [cls] has allocated subtypes.
  bool hasAllocatedSubtypes(TFClass cls);

  late final Type intType = fromStaticType(
    coreTypes.intNonNullableRawType,
    false,
  );
}

/// Base class for type expressions.
/// Type expression is either a [Type] or a statement in a summary.
abstract class TypeExpr {
  const TypeExpr();

  /// Returns computed type of this type expression.
  /// [types] is the list of types computed for the statements in the summary.
  Type getComputedType(List<Type?> types);
}

/// Base class for types inferred by the type flow analysis.
/// [Type] describes a specific set of values (Dart instances) and does not
/// directly correspond to a Dart type.
/// TODO(alexmarkov): consider detaching Type hierarchy from TypeExpr/Statement.
abstract class Type extends TypeExpr {
  const Type._();

  /// Returns a nullable type, union of [this] and the `null` object.
  NullableType nullable();

  Class? getConcreteClass(TypeHierarchy typeHierarchy) => null;

  Closure? get closure => null;

  bool isSubtypeOf(TFClass cls) => false;

  // Returns 'true' if this type will definitely pass a runtime type-check
  // against 'runtimeType'. Returns 'false' if the test might fail (e.g. due to
  // an approximation).
  bool isSubtypeOfRuntimeType(
    TypeHierarchy typeHierarchy,
    RuntimeType runtimeType,
  );

  @override
  Type getComputedType(List<Type?> types) => this;

  /// Order of precedence for evaluation of union/intersection.
  int get order;

  /// Returns true iff this type is fully specialized.
  bool get isSpecialized => true;

  /// Returns specialization of this type using the given [TypeHierarchy].
  Type specialize(TypeHierarchy typeHierarchy) => this;

  /// Returns true if specialization of this type is empty.
  ///
  /// This method is more precise than `type == emptyType` or
  /// `type is EmptyType` tests as specialization can be more precise
  /// than the type.
  ///
  /// This method is more efficient than `type.specialize(...) is EmptyType`
  /// as it omits calculation of specialization. Also, unlike [specialize]
  /// this method doesn't add a dependency if specialization is not empty
  /// (specialization can only grow over time when new allocated
  /// classes are discovered).
  bool hasEmptySpecialization(TypeHierarchy typeHierarchy) => false;

  /// Calculate union of this and [other] types.
  ///
  /// This method is used when calculating type flow throughout the program.
  /// It is correct (although less accurate) for [union] to return
  /// a larger set. In such case analysis would admit that a larger set of
  /// values can flow through the program.
  Type union(Type other, TypeHierarchy typeHierarchy);

  /// Calculate intersection of this and [other] types.
  ///
  /// This method is used when calculating type flow throughout the program.
  /// It is correct (although less accurate) for [intersection] to return
  /// a larger set. In such case analysis would admit that a larger set of
  /// values can flow through the program.
  Type intersection(Type other, TypeHierarchy typeHierarchy);
}

/// Order of precedence between types for evaluation of union/intersection.
enum TypeOrder {
  RuntimeType,
  Unknown,
  Empty,
  Nullable,
  Any,
  WideCone,
  Set,
  Cone,
  Concrete,
}

const emptyType = const EmptyType._();
const nullableEmptyType = const NullableType._(emptyType);

/// Type representing the empty set of instances.
class EmptyType extends Type {
  const EmptyType._() : super._();

  @override
  NullableType nullable() => nullableEmptyType;

  @override
  int get hashCode => 997;

  @override
  bool operator ==(other) => (other is EmptyType);

  @override
  String toString() => "_T {}";

  @override
  int get order => TypeOrder.Empty.index;

  @override
  bool hasEmptySpecialization(TypeHierarchy typeHierarchy) => true;

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) => other;

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) => this;

  bool isSubtypeOfRuntimeType(TypeHierarchy typeHierarchy, RuntimeType other) {
    return true;
  }
}

/// Nullable type represents a union of a (non-nullable) type and the `null`
/// object. Other kinds of types do not contain `null` object (even AnyInstanceType).
class NullableType extends Type {
  final Type baseType;

  const NullableType._(this.baseType)
    : assert(baseType is! NullableType),
      super._();

  @override
  NullableType nullable() => this;

  @override
  int get hashCode {
    const int seed = 31;
    return combineHashes(seed, baseType.hashCode);
  }

  @override
  bool operator ==(other) =>
      identical(this, other) ||
      (other is NullableType) && (this.baseType == other.baseType);

  @override
  String toString() => "${baseType}?";

  @override
  bool isSubtypeOf(TFClass cls) => baseType.isSubtypeOf(cls);

  bool isSubtypeOfRuntimeType(TypeHierarchy typeHierarchy, RuntimeType other) {
    if (other.nullability == Nullability.nonNullable) {
      return false;
    }
    return baseType.isSubtypeOfRuntimeType(typeHierarchy, other);
  }

  @override
  int get order => TypeOrder.Nullable.index;

  @override
  bool get isSpecialized => baseType.isSpecialized;

  @override
  Type specialize(TypeHierarchy typeHierarchy) =>
      baseType.isSpecialized
          ? this
          : baseType.specialize(typeHierarchy).nullable();

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (other.order < this.order) {
      return other.union(this, typeHierarchy);
    }
    if (other is NullableType) {
      return baseType.union(other.baseType, typeHierarchy).nullable();
    } else {
      return baseType.union(other, typeHierarchy).nullable();
    }
  }

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (other.order < this.order) {
      return other.intersection(this, typeHierarchy);
    }
    if (other is NullableType) {
      return baseType.intersection(other.baseType, typeHierarchy).nullable();
    } else {
      return baseType.intersection(other, typeHierarchy);
    }
  }
}

const anyInstanceType = const AnyInstanceType._();
const nullableAnyType = const NullableType._(anyInstanceType);

/// Type representing any instance except `null`.
/// Semantically equivalent to ConeType of Object, but more efficient.
class AnyInstanceType extends Type {
  const AnyInstanceType._() : super._();

  @override
  NullableType nullable() => nullableAnyType;

  @override
  int get hashCode => 991;

  @override
  bool operator ==(other) => (other is AnyInstanceType);

  @override
  String toString() => "_T ANY";

  @override
  int get order => TypeOrder.Any.index;

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (other.order < this.order) {
      return other.union(this, typeHierarchy);
    }
    return this;
  }

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (other.order < this.order) {
      return other.intersection(this, typeHierarchy);
    }
    return other;
  }

  bool isSubtypeOfRuntimeType(TypeHierarchy typeHierarchy, RuntimeType other) {
    final rhs = other._type;
    return (rhs is DynamicType) ||
        (rhs is VoidType) ||
        (rhs is InterfaceType &&
            rhs.classNode == typeHierarchy.coreTypes.objectClass);
  }
}

/// SetType is a union of concrete types T1, T2, ..., Tn, where n >= 2.
/// It represents the set of instances which types are in the {T1, T2, ..., Tn}.
class SetType extends Type {
  /// List of concrete types, sorted by classId.
  final List<ConcreteType> types;

  late final NullableType _nullableType = NullableType._(this);

  @override
  NullableType nullable() => _nullableType;

  @override
  late final int hashCode = _computeHashCode();

  /// Creates a new SetType using list of concrete types sorted by classId.
  SetType(this.types) : super._() {
    assert(types.length >= 2);
    assert(isSorted(types));
  }

  int _computeHashCode() {
    const int seed = 1237;
    int hash = seed;
    for (int i = 0; i < types.length; i++) {
      hash = combineHashes(hash, types[i].hashCode);
    }
    return hash;
  }

  @override
  bool operator ==(other) {
    if (identical(this, other)) return true;
    if ((other is SetType) && (types.length == other.types.length)) {
      for (int i = 0; i < types.length; i++) {
        if (types[i] != other.types[i]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  @override
  String toString() => "_T ${types}";

  @override
  Class? getConcreteClass(TypeHierarchy typeHierarchy) {
    Class? result;
    for (final t in types) {
      final cls = t.getConcreteClass(typeHierarchy);
      if (cls == null) {
        return null;
      }
      if (result == null) {
        result = cls;
      } else if (result != cls) {
        return null;
      }
    }
    return result;
  }

  @override
  bool isSubtypeOf(TFClass cls) =>
      types.every((ConcreteType t) => t.isSubtypeOf(cls));

  bool isSubtypeOfRuntimeType(TypeHierarchy typeHierarchy, RuntimeType other) =>
      types.every((t) => t.isSubtypeOfRuntimeType(typeHierarchy, other));

  @override
  int get order => TypeOrder.Set.index;

  static final ConcreteType _placeholderType = ConcreteType._(
    TFClass(-1, Class(name: '', fileUri: Uri()), {}, null),
    null,
    null,
  );

  static List<ConcreteType> _unionLists(
    List<ConcreteType> types1,
    List<ConcreteType> types2,
  ) {
    int i1 = 0;
    int i2 = 0;
    int newLength = 0;
    // Pre-allocate a List that is the maximum possible length of the result to
    // avoid multiple expensive grow operations. Shrink the List to the correct
    // size at the end.
    List<ConcreteType> types = List.filled(
      types1.length + types2.length,
      _placeholderType,
      growable: true,
    );
    while ((i1 < types1.length) && (i2 < types2.length)) {
      final t1 = types1[i1];
      final t2 = types2[i2];
      if (identical(t1, t2)) {
        types[newLength++] = t1;
        ++i1;
        ++i2;
        continue;
      }
      final id1 = t1.cls.id;
      final id2 = t2.cls.id;
      if (id1 < id2) {
        types[newLength++] = t1;
        ++i1;
      } else if (id1 > id2) {
        types[newLength++] = t2;
        ++i2;
      } else {
        types[newLength++] = t1.raw;
        ++i1;
        ++i2;
      }
    }
    if (i1 < types1.length) {
      for (int i = i1; i < types1.length; i++) {
        types[newLength++] = types1[i];
      }
    } else if (i2 < types2.length) {
      for (int i = i2; i < types2.length; i++) {
        types[newLength++] = types2[i];
      }
    }
    return types..length = newLength;
  }

  static List<ConcreteType> _intersectLists(
    List<ConcreteType> types1,
    List<ConcreteType> types2,
    TypeHierarchy typeHierarchy,
  ) {
    int i1 = 0;
    int i2 = 0;
    List<ConcreteType> types = <ConcreteType>[];
    while ((i1 < types1.length) && (i2 < types2.length)) {
      final t1 = types1[i1];
      final t2 = types2[i2];
      if (identical(t1, t2)) {
        types.add(t1);
        ++i1;
        ++i2;
        continue;
      }
      final id1 = t1.cls.id;
      final id2 = t2.cls.id;
      if (id1 < id2) {
        ++i1;
      } else if (id1 > id2) {
        ++i2;
      } else {
        final intersect = t1.intersection(t2, typeHierarchy);
        if (intersect is! EmptyType) {
          types.add(intersect as ConcreteType);
        }
        ++i1;
        ++i2;
      }
    }
    return types;
  }

  bool _isSubList(List<ConcreteType> sublist, List<ConcreteType> list) {
    int i1 = 0;
    int i2 = 0;
    while ((i1 < sublist.length) && (i2 < list.length)) {
      final t1 = sublist[i1];
      final t2 = list[i2];
      if (identical(t1, t2)) {
        ++i1;
        ++i2;
      } else if (t1.cls.id > t2.cls.id) {
        ++i2;
      } else {
        return false;
      }
    }
    return i1 == sublist.length;
  }

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (identical(this, other)) return this;
    if (other.order < this.order) {
      return other.union(this, typeHierarchy);
    }
    if (other is SetType) {
      if (types.length >= other.types.length) {
        if (_isSubList(other.types, types)) {
          return this;
        }
      } else {
        if (_isSubList(types, other.types)) {
          return other;
        }
      }
      return SetType(_unionLists(types, other.types));
    } else if (other is ConcreteType) {
      // Use binary search since types is sorted by class id.
      // [ConcreteType.compareTo] doesn't take into account type arguments for a
      // given class so we still have to check equality for any types with a
      // matching class.
      int index = binarySearch(types, other);
      if (index == -1) {
        return SetType(_unionLists(types, <ConcreteType>[other]));
      }
      while (index < types.length && types[index].cls.id == other.cls.id) {
        if (types[index] == other) return this;
        ++index;
      }
      return SetType(_unionLists(types, <ConcreteType>[other]));
    } else if (other is ConeType) {
      return typeHierarchy
          .specializeTypeCone(other.cls, allowWideCone: true)
          .union(this, typeHierarchy);
    } else {
      throw 'Unexpected type $other';
    }
  }

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (identical(this, other)) return this;
    if (other.order < this.order) {
      return other.intersection(this, typeHierarchy);
    }
    if (other is SetType) {
      List<ConcreteType> list = _intersectLists(
        types,
        other.types,
        typeHierarchy,
      );
      final size = list.length;
      if (size == 0) {
        return emptyType;
      } else if (size == 1) {
        return list.single;
      } else {
        return SetType(list);
      }
    } else if (other is ConcreteType) {
      for (var type in types) {
        if (type == other) return other;
        if (identical(type.cls, other.cls)) {
          return type.intersection(other, typeHierarchy);
        }
      }
      return emptyType;
    } else if (other is ConeType) {
      return typeHierarchy
          .specializeTypeCone(other.cls, allowWideCone: true)
          .intersection(this, typeHierarchy);
    } else {
      throw 'Unexpected type $other';
    }
  }
}

/// Type representing a subtype cone. It contains instances of all
/// Dart types which extend, mix-in or implement certain class.
/// TODO(alexmarkov): Introduce cones of types which extend but not implement.
class ConeType extends Type {
  final TFClass cls;

  ConeType._(this.cls) : super._();

  late final NullableType _nullableType = NullableType._(this);

  @override
  NullableType nullable() => _nullableType;

  @override
  Class? getConcreteClass(TypeHierarchy typeHierarchy) => typeHierarchy
      .specializeTypeCone(cls, allowWideCone: true)
      .getConcreteClass(typeHierarchy);

  @override
  bool isSubtypeOf(TFClass cls) => this.cls.isSubtypeOf(cls);

  bool isSubtypeOfRuntimeType(TypeHierarchy typeHierarchy, RuntimeType other) {
    final rhs = other._type;
    if (rhs is DynamicType || rhs is VoidType) return true;
    if (rhs is InterfaceType) {
      return cls.classNode.typeParameters.isEmpty &&
          typeHierarchy.isSubtype(cls.classNode, rhs.classNode);
    }
    return false;
  }

  @override
  int get hashCode {
    const int seed = 37;
    return combineHashes(seed, cls.id);
  }

  @override
  bool operator ==(other) => identical(this, other);

  @override
  String toString() => "_T (${cls})+";

  @override
  int get order => TypeOrder.Cone.index;

  @override
  bool get isSpecialized => false;

  @override
  Type specialize(TypeHierarchy typeHierarchy) =>
      typeHierarchy.specializeTypeCone(cls, allowWideCone: true);

  @override
  bool hasEmptySpecialization(TypeHierarchy typeHierarchy) =>
      !cls.hasDynamicallyExtendableSubtypes &&
      !typeHierarchy.hasAllocatedSubtypes(cls);

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (identical(this, other)) return this;
    if (other.order < this.order) {
      return other.union(this, typeHierarchy);
    }
    if (other is ConeType) {
      if (this == other) {
        return this;
      }
      if (other.hasEmptySpecialization(typeHierarchy) ||
          other.cls.isSubtypeOf(this.cls)) {
        return this;
      }
      if (this.hasEmptySpecialization(typeHierarchy) ||
          this.cls.isSubtypeOf(other.cls)) {
        return other;
      }
    } else if (other is ConcreteType) {
      if (other.cls.isSubtypeOf(this.cls)) {
        return this;
      }
    }
    return typeHierarchy
        .specializeTypeCone(cls, allowWideCone: true)
        .union(other, typeHierarchy);
  }

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (identical(this, other)) return this;
    if (other.order < this.order) {
      return other.intersection(this, typeHierarchy);
    }
    if (other is ConeType) {
      if (this == other) {
        return this;
      }
      if (this.hasEmptySpecialization(typeHierarchy) ||
          other.hasEmptySpecialization(typeHierarchy)) {
        return emptyType;
      }
      if (other.cls.isSubtypeOf(this.cls)) {
        return other;
      }
      if (this.cls.isSubtypeOf(other.cls)) {
        return this;
      }
    } else if (other is ConcreteType) {
      if (other.cls.isSubtypeOf(this.cls)) {
        return other;
      } else {
        return emptyType;
      }
    }
    return typeHierarchy
        .specializeTypeCone(cls, allowWideCone: true)
        .intersection(other, typeHierarchy);
  }
}

/// Type representing a subtype cone which has too many concrete classes
/// or may contain dynamically loaded subtypes (unknown at compilation time).
/// It contains instances of all Dart types which extend, mix-in or implement
/// certain class.
class WideConeType extends ConeType {
  WideConeType(TFClass cls) : super._(cls);

  @override
  Class? getConcreteClass(TypeHierarchy typeHierarchy) => null;

  @override
  int get hashCode {
    const int seed = 41;
    return combineHashes(seed, cls.id);
  }

  @override
  bool operator ==(other) =>
      identical(this, other) ||
      (other is WideConeType) && identical(this.cls, other.cls);

  @override
  String toString() => "_T (${cls})++";

  @override
  int get order => TypeOrder.WideCone.index;

  @override
  bool get isSpecialized => true;

  @override
  Type specialize(TypeHierarchy typeHierarchy) => this;

  @override
  bool hasEmptySpecialization(TypeHierarchy typeHierarchy) => false;

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (identical(this, other)) return this;
    if (other.order < this.order) {
      return other.union(this, typeHierarchy);
    }
    if (other is ConeType) {
      if (other.hasEmptySpecialization(typeHierarchy) ||
          other.cls.isSubtypeOf(this.cls)) {
        return this;
      }
      if (this.cls.isSubtypeOf(other.cls)) {
        return other;
      }
    } else if (other is ConcreteType) {
      if (other.cls.isSubtypeOf(this.cls)) {
        return this;
      }
      if (this.cls.isSubtypeOf(other.cls)) {
        return other.cls.coneType;
      }
    } else if (other is SetType) {
      bool subtypes = true;
      for (ConcreteType t in other.types) {
        if (!t.cls.isSubtypeOf(this.cls)) {
          subtypes = false;
          break;
        }
      }
      if (subtypes) {
        return this;
      }
    } else {
      throw 'Unexpected type $other';
    }
    // Wider approximation.
    return anyInstanceType;
  }

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (identical(this, other)) return this;
    if (other.order < this.order) {
      return other.intersection(this, typeHierarchy);
    }
    if (other is ConeType) {
      if (other.hasEmptySpecialization(typeHierarchy)) {
        return emptyType;
      }
      if (other.cls.isSubtypeOf(this.cls)) {
        return other;
      }
    } else if (other is ConcreteType) {
      if (other.cls.isSubtypeOf(this.cls)) {
        return other;
      } else {
        return emptyType;
      }
    } else if (other is SetType) {
      final list = <ConcreteType>[];
      for (ConcreteType t in other.types) {
        if (t.cls.isSubtypeOf(this.cls)) {
          list.add(t);
        }
      }
      final size = list.length;
      if (size == 0) {
        return emptyType;
      } else if (size == 1) {
        return list.single;
      } else if (size == other.types.length) {
        return other;
      } else {
        return SetType(list);
      }
    } else {
      throw 'Unexpected type $other';
    }
    // Wider approximation.
    return this;
  }
}

/// Object representing a closure function.
///
/// Can be used to represent local function (FunctionExpression,
// FunctionDeclaration) or tear-off of Procedure or Constructor.
class Closure {
  final Member member;
  final LocalFunction? function;

  Closure(this.member, this.function);

  // Create a synthetic 'call' method.
  Procedure createCallMethod() {
    final localFunction = this.function;
    final functionNode =
        (localFunction != null) ? localFunction.function : member.function!;
    final typeParameters =
        (localFunction == null && member is Constructor)
            ? member.enclosingClass!.typeParameters
            : functionNode.typeParameters;
    final freshTypeParameters = getFreshTypeParameters(typeParameters);
    List<VariableDeclaration> convertParameters(
      List<VariableDeclaration> params,
    ) => [
      for (final p in params)
        VariableDeclaration(
          p.name,
          initializer:
              (p.initializer != null)
                  ? ConstantExpression(
                    (p.initializer as ConstantExpression).constant,
                  )
                  : null,
          type: freshTypeParameters.substitute(p.type),
          flags: p.flags,
        ),
    ];
    return Procedure(
      Name.callName,
      ProcedureKind.Method,
      FunctionNode(
        null,
        typeParameters: freshTypeParameters.freshTypeParameters,
        positionalParameters: convertParameters(
          functionNode.positionalParameters,
        ),
        namedParameters: convertParameters(functionNode.namedParameters),
        requiredParameterCount: functionNode.requiredParameterCount,
        returnType: freshTypeParameters.substitute(functionNode.returnType),
      ),
      isExternal: true,
      isSynthetic: true,
      isStatic: false,
      fileUri: artificialNodeUri,
    );
  }

  @override
  int get hashCode => combineHashes(member.hashCode, function.hashCode);

  @override
  bool operator ==(other) {
    if (identical(this, other)) return true;
    if (other is! Closure) return false;
    return (this.member == other.member) && (this.function == other.function);
  }

  @override
  String toString() {
    final function = this.function;
    if (function == null) {
      return 'tear-off ${nodeToText(member)}';
    }
    return localFunctionName(function);
  }
}

/// Disjoint (mutually exclusive) attributes of Dart values.
///
/// If two sets of values V1 and V2 are known to have
/// distinct attributes A1 != A2, then Intersection(V1, V2) is empty.
///
/// Currently used for
///  - constant values;
///  - closures.
///
class TypeAttributes {
  final Constant? constant;
  final Closure? closure;

  TypeAttributes._(this.constant, this.closure)
    : hashCode = constant.hashCode ^ closure.hashCode {
    assert(constant != null || closure != null);
  }

  @override
  final int hashCode;

  @override
  bool operator ==(other) {
    if (identical(this, other)) return true;
    if (other is! TypeAttributes) return false;
    return (this.constant == other.constant) && (this.closure == other.closure);
  }

  @override
  String toString() {
    final buf = StringBuffer();
    final constant = this.constant;
    if (constant != null) {
      buf.write(nodeToText(constant));
    }
    final closure = this.closure;
    if (closure != null) {
      if (buf.isNotEmpty) {
        buf.write(', ');
      }
      buf.write(closure.toString());
    }
    return buf.toString();
  }
}

/// Type representing a set of instances of a specific Dart class (no subtypes
/// or `null` object).
class ConcreteType extends Type implements Comparable<ConcreteType> {
  final TFClass cls;

  late final NullableType _nullableType = NullableType._(this);

  @override
  NullableType nullable() => _nullableType;

  @override
  late final int hashCode = _computeHashCode();

  // May be null if there are no type arguments constraints. The type arguments
  // should represent type sets, i.e. `UnknownType` or `RuntimeType`. The type
  // arguments vector is factored against the generic interfaces implemented by
  // the class (see [TypeHierarchy.flattenedTypeArgumentsFor]).
  //
  // The 'typeArgs' vector is null for non-generic classes, even if they
  // implement a generic interface.
  //
  // 'numImmediateTypeArgs' is the length of the prefix of 'typeArgs' which
  // holds the type arguments to the class itself.
  final int numImmediateTypeArgs;
  final List<Type>? typeArgs;

  // Additional type attributes such as constant value and
  // inferred closure.
  final TypeAttributes? attributes;

  ConcreteType._(this.cls, List<Type>? typeArgs_, this.attributes)
    : typeArgs = typeArgs_,
      numImmediateTypeArgs =
          typeArgs_ != null ? cls.classNode.typeParameters.length : 0,
      super._() {
    assert(!cls.classNode.isAbstract);
    assert(typeArgs == null || cls.classNode.typeParameters.isNotEmpty);
    assert(typeArgs == null || typeArgs!.any((t) => t is RuntimeType));
  }

  ConcreteType(TFClass cls, List<Type> typeArgs) : this._(cls, typeArgs, null);

  ConcreteType get raw => cls.concreteType;
  bool get isRaw => typeArgs == null && attributes == null;

  @override
  Class? getConcreteClass(TypeHierarchy typeHierarchy) =>
      filterArtificialNode(cls.classNode);

  @override
  Closure? get closure => attributes?.closure;

  @override
  bool isSubtypeOf(TFClass other) => cls.isSubtypeOf(other);

  bool isSubtypeOfRuntimeType(
    TypeHierarchy typeHierarchy,
    RuntimeType runtimeType,
  ) {
    final rhs = runtimeType._type;
    if (rhs is DynamicType || rhs is VoidType) return true;
    if (rhs is InterfaceType) {
      if (rhs.classNode == typeHierarchy.coreTypes.functionClass) {
        // TODO(35573): "implements/extends Function" is not handled correctly by
        // the CFE. By returning "false" we force an approximation -- that a type
        // check against "Function" might fail, whatever the LHS is.
        return false;
      }

      if (!typeHierarchy.isSubtype(this.cls.classNode, rhs.classNode)) {
        return false;
      }

      if (rhs.typeArguments.isEmpty) return true;

      List<Type>? usableTypeArgs = typeArgs;
      if (usableTypeArgs == null) {
        if (cls.classNode.typeParameters.isEmpty) {
          usableTypeArgs = typeHierarchy.flattenedTypeArgumentsForNonGeneric(
            cls.classNode,
          );
        } else {
          return false;
        }
      }

      final interfaceOffset = typeHierarchy.genericInterfaceOffsetFor(
        cls.classNode,
        rhs.classNode,
      );

      assert(
        usableTypeArgs.length - interfaceOffset >=
            runtimeType.numImmediateTypeArgs,
      );

      for (int i = 0; i < runtimeType.numImmediateTypeArgs; ++i) {
        final ta = usableTypeArgs[i + interfaceOffset];
        if (ta is UnknownType) {
          return false;
        }
        assert(ta is RuntimeType);
        if (!ta.isSubtypeOfRuntimeType(
          typeHierarchy,
          runtimeType.typeArgs![i],
        )) {
          return false;
        }
      }
      return true;
    }
    if (rhs is FutureOrType) {
      if (typeHierarchy.isSubtype(
        cls.classNode,
        typeHierarchy.coreTypes.futureClass,
      )) {
        Type typeArg;
        if (typeArgs == null) {
          typeArg = unknownType;
        } else {
          final interfaceOffset = typeHierarchy.genericInterfaceOffsetFor(
            cls.classNode,
            typeHierarchy.coreTypes.futureClass,
          );
          typeArg = typeArgs![interfaceOffset];
        }
        final RuntimeType lhs =
            typeArg is RuntimeType ? typeArg : RuntimeType(DynamicType(), null);
        return lhs.isSubtypeOfRuntimeType(
          typeHierarchy,
          runtimeType.typeArgs![0],
        );
      } else {
        return isSubtypeOfRuntimeType(typeHierarchy, runtimeType.typeArgs![0]);
      }
    }
    return false;
  }

  int _computeHashCode() {
    const int seed = 43;
    int hash = combineHashes(seed, cls.hashCode);
    // We only need to hash the first type arguments vector, since the type
    // arguments of the implemented interfaces are implied by it.
    for (int i = 0; i < numImmediateTypeArgs; ++i) {
      hash = combineHashes(hash, typeArgs![i].hashCode);
    }
    hash = combineHashes(hash, attributes.hashCode);
    return hash;
  }

  @override
  bool operator ==(other) {
    if (identical(this, other)) return true;
    if (other is ConcreteType) {
      if (!identical(this.cls, other.cls) ||
          this.numImmediateTypeArgs != other.numImmediateTypeArgs ||
          !identical(this.attributes, other.attributes)) {
        return false;
      }
      if (this.typeArgs != null) {
        for (int i = 0; i < numImmediateTypeArgs; ++i) {
          if (this.typeArgs![i] != other.typeArgs![i]) {
            return false;
          }
        }
      }
      return true;
    } else {
      return false;
    }
  }

  // Note that this may return 0 for concrete types which are not equal if the
  // difference is only in type arguments.
  @override
  int compareTo(ConcreteType other) => cls.id.compareTo(other.cls.id);

  @override
  String toString() {
    if (typeArgs == null && attributes == null) {
      return "_T (${cls})";
    }
    final StringBuffer buf = new StringBuffer();
    buf.write("_T (${cls}");
    if (typeArgs != null) {
      buf.write("<${typeArgs!.take(numImmediateTypeArgs).join(', ')}>");
    }
    if (attributes != null) {
      buf.write(", $attributes");
    }
    buf.write(")");
    return buf.toString();
  }

  @override
  int get order => TypeOrder.Concrete.index;

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (other.order < this.order) {
      return other.union(this, typeHierarchy);
    }
    if (other is ConcreteType) {
      if (this == other) {
        return this;
      } else if (!identical(this.cls, other.cls)) {
        final types =
            (this.cls.id < other.cls.id)
                ? <ConcreteType>[this, other]
                : <ConcreteType>[other, this];
        return SetType(types);
      } else {
        assert(
          typeArgs != null ||
              attributes != null ||
              other.typeArgs != null ||
              other.attributes != null,
        );
        return raw;
      }
    } else {
      throw 'Unexpected type $other';
    }
  }

  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (other.order < this.order) {
      return other.intersection(this, typeHierarchy);
    }
    if (other is ConcreteType) {
      if (this == other) {
        return this;
      }
      if (!identical(this.cls, other.cls)) {
        return emptyType;
      }
      if (attributes != null) {
        if (other.attributes == null) {
          return this;
        }
        assert(attributes != other.attributes);
        return emptyType;
      } else if (other.attributes != null) {
        return other;
      }

      final thisTypeArgs = this.typeArgs;
      final otherTypeArgs = other.typeArgs;
      if (thisTypeArgs == null) {
        return other;
      } else if (otherTypeArgs == null) {
        return this;
      } else {
        assert(thisTypeArgs.length == otherTypeArgs.length);
        final mergedTypeArgs = List<Type>.filled(
          thisTypeArgs.length,
          emptyType,
        );
        bool hasRuntimeType = false;
        for (int i = 0; i < thisTypeArgs.length; ++i) {
          final merged = thisTypeArgs[i].intersection(
            otherTypeArgs[i],
            typeHierarchy,
          );
          if (merged is EmptyType) {
            return emptyType;
          } else if (merged is RuntimeType) {
            hasRuntimeType = true;
          }
          mergedTypeArgs[i] = merged;
        }
        if (!hasRuntimeType) {
          return cls.concreteType;
        }
        return ConcreteType(cls, mergedTypeArgs);
      }
    } else {
      throw 'Unexpected type $other';
    }
  }
}

// Unlike the other 'Type's, this represents a single type, not a set of
// values. It is used as the right-hand-side of type-tests.
//
// The type arguments are represented in a form that is factored against the
// generic interfaces implemented by the type to enable efficient type-test
// against its interfaces. See 'TypeHierarchy.flattenedTypeArgumentsFor' for
// more details.
//
// This factored representation can have cycles for some types:
//
//   class num implements Comparable<num> {}
//   class A<T> extends Comparable<A<T>> {}
//
// To avoid these cycles, we approximate generic super-bounded types (the second
// case), so the representation for 'A<String>' would be simply 'UnknownType'.
// However, approximating non-generic types like 'int' and 'num' (the first
// case) would be too coarse, so we leave an null 'typeArgs' field for these
// types. As a result, when doing an 'isSubtypeOfRuntimeType' against
// their interfaces (e.g. 'int' vs 'Comparable<int>') we approximate the result
// as 'false'.
//
// So, the invariant about 'typeArgs' is that they will be 'null' iff the class
// is non-generic, and non-null (with at least one vector) otherwise.
class RuntimeType extends Type {
  final DartType _type; // Doesn't contain type args.

  final int numImmediateTypeArgs;
  final List<RuntimeType>? typeArgs;

  RuntimeType(DartType type, this.typeArgs)
    : _type = type,
      numImmediateTypeArgs =
          type is InterfaceType
              ? type.classNode.typeParameters.length
              : (type is FutureOrType ? 1 : 0),
      super._() {
    if (_type is InterfaceType && numImmediateTypeArgs > 0) {
      assert(typeArgs!.length >= numImmediateTypeArgs);
      assert(_type.typeArguments.every((t) => t == const DynamicType()));
    } else if (_type is FutureOrType) {
      assert(typeArgs!.length >= numImmediateTypeArgs);
      DartType typeArgument = _type.typeArgument;
      assert(typeArgument == const DynamicType());
    } else {
      assert(typeArgs == null);
    }
  }

  int get order => TypeOrder.RuntimeType.index;

  Nullability get nullability => _type.declaredNullability;

  RuntimeType withNullability(Nullability n) =>
      RuntimeType(_type.withDeclaredNullability(n), typeArgs);

  RuntimeType applyNullability(Nullability nullability) {
    final thisNullability = this.nullability;
    if (thisNullability != nullability) {
      Nullability result;
      if (thisNullability == Nullability.nullable ||
          nullability == Nullability.nullable) {
        result = Nullability.nullable;
      } else {
        result = Nullability.nonNullable;
      }
      if (thisNullability != result) {
        return withNullability(result);
      }
    }
    return this;
  }

  DartType get representedTypeRaw => _type;

  DartType get representedType {
    final type = _type;
    if (type is InterfaceType && typeArgs != null) {
      final klass = type.classNode;
      final typeArguments =
          typeArgs!
              .take(klass.typeParameters.length)
              .map((pt) => pt.representedType)
              .toList();
      return new InterfaceType(klass, type.nullability, typeArguments);
    } else if (type is FutureOrType) {
      return new FutureOrType(typeArgs![0].representedType, type.nullability);
    } else {
      return type;
    }
  }

  @override
  late final int hashCode = _computeHashCode();

  int _computeHashCode() {
    const int seed = 47;
    int hash = combineHashes(seed, _type.hashCode);
    // Only hash by the type arguments of the class. The type arguments of
    // supertypes are implied by them.
    for (int i = 0; i < numImmediateTypeArgs; ++i) {
      hash = combineHashes(hash, typeArgs![i].hashCode);
    }
    return hash;
  }

  @override
  operator ==(other) {
    if (identical(this, other)) return true;
    if (other is RuntimeType) {
      if (other._type != _type) return false;
      assert(numImmediateTypeArgs == other.numImmediateTypeArgs);
      return typeArgs == null || listEquals(typeArgs!, other.typeArgs!);
    }
    return false;
  }

  @override
  String toString() {
    final head =
        _type is InterfaceType
            ? "${nodeToText(_type.classNode)}"
            : "${nodeToText(_type)}";
    final typeArgsStrs =
        (numImmediateTypeArgs == 0)
            ? ""
            : "<${typeArgs!.take(numImmediateTypeArgs).map((t) => "$t").join(", ")}>";
    final nullability = _type.nullability.suffix;
    return "$head$typeArgsStrs$nullability";
  }

  @override
  NullableType nullable() =>
      throw "ERROR: RuntimeType does not support nullable().";

  @override
  bool get isSpecialized =>
      throw "ERROR: RuntimeType does not support isSpecialized.";

  @override
  bool isSubtypeOf(TFClass cls) =>
      throw "ERROR: RuntimeType does not support isSubtypeOf.";

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) =>
      throw "ERROR: RuntimeType does not support union.";

  // This only works between "type-set" representations ('UnknownType' and
  // 'RuntimeType') and is used when merging type arguments.
  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (other is UnknownType) {
      return this;
    } else if (other is RuntimeType) {
      return this == other ? this : emptyType;
    }
    throw "ERROR: RuntimeType cannot intersect with ${other.runtimeType}";
  }

  @override
  Type specialize(TypeHierarchy typeHierarchy) =>
      throw "ERROR: RuntimeType does not support specialize.";

  @override
  Class? getConcreteClass(TypeHierarchy typeHierarchy) =>
      throw "ERROR: RuntimeType does not support getConcreteClass.";

  bool isSubtypeOfRuntimeType(
    TypeHierarchy typeHierarchy,
    RuntimeType runtimeType,
  ) {
    final rhs = runtimeType._type;
    if (_type.nullability == Nullability.nullable &&
        rhs.nullability == Nullability.nonNullable) {
      return false;
    }
    if (rhs is DynamicType || rhs is VoidType || _type is NeverType) {
      return true;
    }
    if (_type is NullType) return (rhs.nullability == Nullability.nullable);
    if (rhs is NeverType || rhs is NullType) return false;
    if (_type is DynamicType || _type is VoidType) {
      return (rhs is InterfaceType &&
          rhs.classNode == typeHierarchy.coreTypes.objectClass);
    }

    if (rhs is FutureOrType) {
      if (_type is InterfaceType) {
        Class thisClass = _type.classNode;
        if (thisClass == typeHierarchy.coreTypes.futureClass) {
          return typeArgs![0].isSubtypeOfRuntimeType(
            typeHierarchy,
            runtimeType.typeArgs![0],
          );
        } else {
          return isSubtypeOfRuntimeType(
            typeHierarchy,
            runtimeType.typeArgs![0],
          );
        }
      } else if (_type is FutureOrType) {
        return typeArgs![0].isSubtypeOfRuntimeType(
          typeHierarchy,
          runtimeType.typeArgs![0],
        );
      }
    }

    if (_type is FutureOrType) {
      // There are more possibilities for _type to be a subtype of rhs, such as
      // the following:
      //   1. _type=FutureOr<Future<...>>, rhs=Future<dynamic>
      //   2. _type=FutureOr<X>, rhs=Future<Y>, where X and Y are type
      //      parameters declared as `X extends Y`, `Y extends Future<Y>`.
      // Since it's ok to return false when _type <: rhs in rare cases, only the
      // most common case of rhs being Object is handled here for now.
      // TODO(alexmarkov): Handle other possibilities.
      return rhs is InterfaceType &&
          rhs.classNode == typeHierarchy.coreTypes.objectClass;
    }

    final thisClass = (_type as InterfaceType).classNode;
    final otherClass = (rhs as InterfaceType).classNode;

    if (!typeHierarchy.isSubtype(thisClass, otherClass)) return false;

    // The typeHierarchy result maybe be inaccurate only if there are type
    // arguments which need to be examined.
    if (runtimeType.numImmediateTypeArgs == 0) {
      return true;
    }

    List<Type>? usableTypeArgs = typeArgs;
    if (usableTypeArgs == null) {
      assert(thisClass.typeParameters.isEmpty);
      usableTypeArgs = typeHierarchy.flattenedTypeArgumentsForNonGeneric(
        thisClass,
      );
    }
    final interfaceOffset = typeHierarchy.genericInterfaceOffsetFor(
      thisClass,
      otherClass,
    );
    assert(
      usableTypeArgs.length - interfaceOffset >=
          runtimeType.numImmediateTypeArgs,
    );
    for (int i = 0; i < runtimeType.numImmediateTypeArgs; ++i) {
      if (!usableTypeArgs[interfaceOffset + i].isSubtypeOfRuntimeType(
        typeHierarchy,
        runtimeType.typeArgs![i],
      )) {
        return false;
      }
    }
    return true;
  }
}

const unknownType = const UnknownType._();

/// Type which is not known at compile time.
/// It is used as the right-hand-side of type tests.
class UnknownType extends Type {
  const UnknownType._() : super._();

  @override
  int get hashCode => 1019;

  @override
  bool operator ==(other) => (other is UnknownType);

  @override
  String toString() => "UNKNOWN";

  @override
  int get order => TypeOrder.Unknown.index;

  @override
  NullableType nullable() =>
      throw "ERROR: UnknownType does not support nullable().";

  @override
  bool isSubtypeOf(TFClass cls) =>
      throw "ERROR: UnknownType does not support isSubtypeOf.";

  @override
  Type union(Type other, TypeHierarchy typeHierarchy) {
    if (other is UnknownType || other is RuntimeType) {
      return this;
    }
    throw "ERROR: UnknownType does not support union with ${other.runtimeType}";
  }

  // This only works between "type-set" representations ('UnknownType' and
  // 'RuntimeType') and is used when merging type arguments.
  @override
  Type intersection(Type other, TypeHierarchy typeHierarchy) {
    if (other is UnknownType || other is RuntimeType) {
      return other;
    }
    throw "ERROR: UnknownType does not support intersection with ${other.runtimeType}";
  }

  bool isSubtypeOfRuntimeType(TypeHierarchy typeHierarchy, RuntimeType other) {
    final rhs = other._type;
    return (rhs is DynamicType) ||
        (rhs is VoidType) ||
        (rhs is InterfaceType &&
            rhs.classNode == typeHierarchy.coreTypes.objectClass &&
            rhs.nullability != Nullability.nonNullable);
  }
}
