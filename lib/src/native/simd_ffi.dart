import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../vector/distance.dart';

typedef _NativeDotProduct = Float Function(Pointer<Float>, Pointer<Float>, Int32);
typedef _DartDotProduct = double Function(Pointer<Float>, Pointer<Float>, int);

typedef _NativeEuclideanSq = Float Function(Pointer<Float>, Pointer<Float>, Int32);
typedef _DartEuclideanSq = double Function(Pointer<Float>, Pointer<Float>, int);

typedef _NativeCosine = Float Function(Pointer<Float>, Pointer<Float>, Int32);
typedef _DartCosine = double Function(Pointer<Float>, Pointer<Float>, int);

/// Foreign Function Interface (FFI) bindings for C SIMD vector acceleration.
class SimdFfi {
  static bool _isLoaded = false;
  static DynamicLibrary? _dylib;

  static _DartDotProduct? _nativeDotProduct;
  static _DartEuclideanSq? _nativeEuclideanSq;
  static _DartCosine? _nativeCosine;

  /// Whether the native C SIMD shared library was successfully loaded.
  static bool get isNativeAvailable => _isLoaded;

  /// Attempts to initialize and load the native SIMD library.
  static void initialize([String? libraryPath]) {
    if (_isLoaded) return;

    try {
      if (libraryPath != null) {
        _dylib = DynamicLibrary.open(libraryPath);
      } else if (Platform.isMacOS) {
        _dylib = _tryOpen(['libcorbel_simd.dylib', './native/build/libcorbel_simd.dylib']);
      } else if (Platform.isLinux) {
        _dylib = _tryOpen(['libcorbel_simd.so', './native/build/libcorbel_simd.so']);
      } else if (Platform.isWindows) {
        _dylib = _tryOpen(['corbel_simd.dll', './native/build/corbel_simd.dll']);
      }

      if (_dylib != null) {
        _nativeDotProduct = _dylib!
            .lookup<NativeFunction<_NativeDotProduct>>('corbel_simd_dot_product')
            .asFunction<_DartDotProduct>();
        _nativeEuclideanSq = _dylib!
            .lookup<NativeFunction<_NativeEuclideanSq>>('corbel_simd_euclidean_sq')
            .asFunction<_DartEuclideanSq>();
        _nativeCosine = _dylib!
            .lookup<NativeFunction<_NativeCosine>>('corbel_simd_cosine')
            .asFunction<_DartCosine>();
        _isLoaded = true;
      }
    } catch (_) {
      _isLoaded = false;
    }
  }

  static DynamicLibrary? _tryOpen(List<String> paths) {
    for (final p in paths) {
      if (File(p).existsSync()) {
        try {
          return DynamicLibrary.open(p);
        } catch (_) {}
      }
    }
    return null;
  }

  /// Calculates dot product using SIMD C library or Dart fallback.
  static double dotProduct(Float32List a, Float32List b) {
    if (!_isLoaded || _nativeDotProduct == null) {
      return VectorDistance.dotProduct(a, b);
    }

    final dim = a.length;
    final ptrA = calloc<Float>(dim);
    final ptrB = calloc<Float>(dim);

    try {
      ptrA.asTypedList(dim).setAll(0, a);
      ptrB.asTypedList(dim).setAll(0, b);
      return _nativeDotProduct!(ptrA, ptrB, dim);
    } finally {
      calloc.free(ptrA);
      calloc.free(ptrB);
    }
  }

  /// Calculates squared Euclidean distance using SIMD C library or Dart fallback.
  static double euclideanSq(Float32List a, Float32List b) {
    if (!_isLoaded || _nativeEuclideanSq == null) {
      return VectorDistance.squaredEuclidean(a, b);
    }

    final dim = a.length;
    final ptrA = calloc<Float>(dim);
    final ptrB = calloc<Float>(dim);

    try {
      ptrA.asTypedList(dim).setAll(0, a);
      ptrB.asTypedList(dim).setAll(0, b);
      return _nativeEuclideanSq!(ptrA, ptrB, dim);
    } finally {
      calloc.free(ptrA);
      calloc.free(ptrB);
    }
  }

  /// Calculates cosine similarity using SIMD C library or Dart fallback.
  static double cosine(Float32List a, Float32List b) {
    if (!_isLoaded || _nativeCosine == null) {
      return VectorDistance.cosineSimilarity(a, b);
    }

    final dim = a.length;
    final ptrA = calloc<Float>(dim);
    final ptrB = calloc<Float>(dim);

    try {
      ptrA.asTypedList(dim).setAll(0, a);
      ptrB.asTypedList(dim).setAll(0, b);
      return _nativeCosine!(ptrA, ptrB, dim);
    } finally {
      calloc.free(ptrA);
      calloc.free(ptrB);
    }
  }
}
