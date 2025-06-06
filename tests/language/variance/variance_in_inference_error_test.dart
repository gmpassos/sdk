// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Tests local inference errors for the `in` variance modifier.

// SharedOptions=--enable-experiment=variance

class Covariant<out T> {}
class Contravariant<in T> {}

class Exactly<inout T> {}

class Upper {}
class Middle extends Upper {}
class Lower extends Middle {}

class ContraBound<in T> {
  ContraBound(T x, void Function(T) y) {}
}

Exactly<T> inferCovContra<T>(Covariant<T> x, Contravariant<T> y) => new Exactly<T>();
Exactly<T> inferContraContra<T>(Contravariant<T> x, Contravariant<T> y) => new Exactly<T>();
Exactly<T> inferContraBound<T>(ContraBound<T> x) => new Exactly<T>();

main() {
  Exactly<Upper> upper;
  Exactly<Lower> lower;

  // T <: Upper and T <: Middle.
  // We choose Middle.
  var inferredMiddle = inferContraContra(Contravariant<Upper>(), Contravariant<Middle>());
  upper = inferredMiddle;
  //      ^^^^^^^^^^^^^^
  // [analyzer] COMPILE_TIME_ERROR.INVALID_ASSIGNMENT
  // [cfe] A value of type 'Exactly<Middle>' can't be assigned to a variable of type 'Exactly<Upper>'.

  // T <: Upper and T <: Lower.
  // We choose Lower.
  var inferredLower = inferContraContra(Contravariant<Upper>(), Contravariant<Lower>());
  upper = inferredLower;
  //      ^^^^^^^^^^^^^
  // [analyzer] COMPILE_TIME_ERROR.INVALID_ASSIGNMENT
  // [cfe] A value of type 'Exactly<Lower>' can't be assigned to a variable of type 'Exactly<Upper>'.

  // int <: T <: String is not a valid constraint.
  inferCovContra(Covariant<int>(), Contravariant<String>());
//^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.COULD_NOT_INFER
//                                 ^^^^^^^^^^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
// [cfe] The argument type 'Contravariant<String>' can't be assigned to the parameter type 'Contravariant<int>'.

  // String <: T <: int is not a valid constraint.
  inferCovContra(Covariant<String>(), Contravariant<int>());
//^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.COULD_NOT_INFER
//                                    ^^^^^^^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
// [cfe] The argument type 'Contravariant<int>' can't be assigned to the parameter type 'Contravariant<String>'.

  // Middle <: T <: Lower is not a valid constraint
  inferCovContra(Covariant<Middle>(), Contravariant<Lower>());
//^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.COULD_NOT_INFER
//                                    ^^^^^^^^^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
// [cfe] The argument type 'Contravariant<Lower>' can't be assigned to the parameter type 'Contravariant<Middle>'.

  // Upper <: T <: Lower is not a valid constraint
  inferCovContra(Covariant<Upper>(), Contravariant<Lower>());
//^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.COULD_NOT_INFER
//                                   ^^^^^^^^^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
// [cfe] The argument type 'Contravariant<Lower>' can't be assigned to the parameter type 'Contravariant<Upper>'.

  // Upper <: T <: Middle is not a valid constraint
  inferCovContra(Covariant<Upper>(), Contravariant<Middle>());
//^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.COULD_NOT_INFER
//                                   ^^^^^^^^^^^^^^^^^^^^^^^
// [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
// [cfe] The argument type 'Contravariant<Middle>' can't be assigned to the parameter type 'Contravariant<Upper>'.

  // Inference for Contrabound(...) produces Lower <: T <: Upper.
  // Since T is contravariant, we choose Upper as the solution.
  var inferredContraUpper = inferContraBound(ContraBound(Lower(), (Upper x) {}));
  lower = inferredContraUpper;
  //      ^^^^^^^^^^^^^^^^^^^
  // [analyzer] COMPILE_TIME_ERROR.INVALID_ASSIGNMENT
  // [cfe] A value of type 'Exactly<Upper>' can't be assigned to a variable of type 'Exactly<Lower>'.

  // Inference for Contrabound(...) produces Lower <: T <: Middle.
  // Since T is contravariant, we choose Middle as the solution.
  var inferredContraMiddle = inferContraBound(ContraBound(Lower(), (Middle x) {}));
  lower = inferredContraMiddle;
  //      ^^^^^^^^^^^^^^^^^^^^
  // [analyzer] COMPILE_TIME_ERROR.INVALID_ASSIGNMENT
  // [cfe] A value of type 'Exactly<Middle>' can't be assigned to a variable of type 'Exactly<Lower>'.
}
