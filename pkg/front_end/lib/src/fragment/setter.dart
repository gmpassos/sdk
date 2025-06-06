// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'fragment.dart';

class SetterFragment implements Fragment, FunctionFragment {
  @override
  final String name;

  final Uri fileUri;
  final int startOffset;
  final int nameOffset;
  final int formalsOffset;
  final int endOffset;
  final bool isTopLevel;
  final List<MetadataBuilder>? metadata;
  final Modifiers modifiers;

  /// The declared return type of this setter.
  ///
  /// If the return type was omitted, this is an [InferableTypeBuilder].
  final TypeBuilder returnType;

  /// The name space for the type parameters available on this setter.
  ///
  /// Initially this is empty, since setters don't have type parameters, but for
  /// extension and extension type instance setters this will include type
  /// parameters cloned from the extension or extension type, respectively.
  final NominalParameterNameSpace typeParameterNameSpace;

  /// The declared type parameters on this setter.
  ///
  /// This is only non-null in erroneous cases since setters don't have type
  /// parameters.
  final List<TypeParameterFragment>? declaredTypeParameters;

  /// The scope in which the setter is declared.
  ///
  /// This is the scope used for resolving the [metadata].
  final LookupScope enclosingScope;

  /// The scope that introduces type parameters on this setter.
  ///
  /// This is based on [typeParameterNameSpace] and initially doesn't introduce
  /// any type parameters, since setters don't have type parameters, but for
  /// extension and extension type instance setters this will include type
  /// parameters cloned from the extension or extension type, respectively.
  final LookupScope typeParameterScope;

  /// The declared formals on this setter.
  final List<FormalParameterBuilder>? declaredFormals;

  final AsyncMarker asyncModifier;
  final String? nativeMethodName;

  final DeclarationFragment? enclosingDeclaration;
  final LibraryFragment enclosingCompilationUnit;

  SourcePropertyBuilder? _builder;
  SetterFragmentDeclaration? _declaration;

  SetterFragment({
    required this.name,
    required this.fileUri,
    required this.startOffset,
    required this.nameOffset,
    required this.formalsOffset,
    required this.endOffset,
    required this.isTopLevel,
    required this.metadata,
    required this.modifiers,
    required this.returnType,
    required this.declaredTypeParameters,
    required this.typeParameterNameSpace,
    required this.enclosingScope,
    required this.typeParameterScope,
    required this.declaredFormals,
    required this.asyncModifier,
    required this.nativeMethodName,
    required this.enclosingDeclaration,
    required this.enclosingCompilationUnit,
  });

  @override
  SourcePropertyBuilder get builder {
    assert(_builder != null, "Builder has not been computed for $this.");
    return _builder!;
  }

  void set builder(SourcePropertyBuilder value) {
    assert(_builder == null, "Builder has already been computed for $this.");
    _builder = value;
  }

  SetterFragmentDeclaration get declaration {
    assert(
        _declaration != null, "Declaration has not been computed for $this.");
    return _declaration!;
  }

  void set declaration(SetterFragmentDeclaration value) {
    assert(_declaration == null,
        "Declaration has already been computed for $this.");
    _declaration = value;
  }

  UriOffsetLength get uriOffset =>
      new UriOffsetLength(fileUri, nameOffset, name.length);

  @override
  FunctionBodyBuildingContext createFunctionBodyBuildingContext() {
    return new _SetterFunctionBodyBuildingContext(this);
  }

  @override
  String toString() => '$runtimeType($name,$fileUri,$nameOffset)';
}

class _SetterFunctionBodyBuildingContext
    implements FunctionBodyBuildingContext {
  SetterFragment _fragment;

  _SetterFunctionBodyBuildingContext(this._fragment);

  @override
  MemberKind get memberKind => _fragment.isTopLevel
      ? MemberKind.TopLevelMethod
      : (_fragment.modifiers.isStatic
          ? MemberKind.StaticMethod
          : MemberKind.NonStaticMethod);

  @override
  bool get shouldBuild => true;

  @override
  LocalScope computeFormalParameterScope(LookupScope typeParameterScope) {
    return _fragment.declaration.createFormalParameterScope(typeParameterScope);
  }

  @override
  LookupScope get typeParameterScope {
    return _fragment.typeParameterScope;
  }

  @override
  BodyBuilderContext createBodyBuilderContext() {
    return _fragment.declaration.createBodyBuilderContext(_fragment.builder);
  }

  @override
  InferenceDataForTesting? get inferenceDataForTesting => _fragment
      .builder
      .dataForTesting
      // Coverage-ignore(suite): Not run.
      ?.inferenceData;

  @override
  List<TypeParameter>? get thisTypeParameters =>
      _fragment.declaration.thisTypeParameters;

  @override
  VariableDeclaration? get thisVariable => _fragment.declaration.thisVariable;
}
