#ifndef CORBEL_SIMD_H
#define CORBEL_SIMD_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(__CYGWIN__)
  #ifdef CORBEL_SIMD_EXPORT
    #define CORBEL_API __declspec(dllexport)
  #else
    #define CORBEL_API __declspec(dllimport)
  #endif
#else
  #define CORBEL_API __attribute__((visibility("default")))
#endif

CORBEL_API float corbel_simd_dot_product(const float* a, const float* b, int dim);

CORBEL_API float corbel_simd_euclidean_sq(const float* a, const float* b, int dim);

CORBEL_API float corbel_simd_cosine(const float* a, const float* b, int dim);

CORBEL_API float corbel_simd_manhattan(const float* a, const float* b, int dim);

CORBEL_API void corbel_simd_batch_dot_product(
    const float* query,
    const float* matrix,
    float* results,
    int count,
    int dim
);

#ifdef __cplusplus
}
#endif

#endif // CORBEL_SIMD_H
