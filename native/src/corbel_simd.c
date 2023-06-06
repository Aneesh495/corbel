#include "../include/corbel_simd.h"
#include <math.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  #include <arm_neon.h>
  #define HAS_ARM_NEON 1
#elif defined(__AVX2__)
  #include <immintrin.h>
  #define HAS_AVX2 1
#endif

float corbel_simd_dot_product(const float* a, const float* b, int dim) {
  int i = 0;
  float sum = 0.0f;

#if defined(HAS_ARM_NEON)
  float32x4_t vsum = vdupq_n_f32(0.0f);
  for (; i <= dim - 4; i += 4) {
    float32x4_t va = vld1q_f32(a + i);
    float32x4_t vb = vld1q_f32(b + i);
    vsum = vmlaq_f32(vsum, va, vb);
  }
  sum = vaddvq_f32(vsum);
#elif defined(HAS_AVX2)
  __m256 vsum = _mm256_setzero_ps();
  for (; i <= dim - 8; i += 8) {
    __m256 va = _mm256_loadu_ps(a + i);
    __m256 vb = _mm256_loadu_ps(b + i);
    vsum = _mm256_fmadd_ps(va, vb, vsum);
  }
  float buffer[8];
  _mm256_storeu_ps(buffer, vsum);
  for (int j = 0; j < 8; j++) sum += buffer[j];
#endif

  // Scalar tail
  for (; i < dim; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

float corbel_simd_euclidean_sq(const float* a, const float* b, int dim) {
  int i = 0;
  float sum = 0.0f;

#if defined(HAS_ARM_NEON)
  float32x4_t vsum = vdupq_n_f32(0.0f);
  for (; i <= dim - 4; i += 4) {
    float32x4_t va = vld1q_f32(a + i);
    float32x4_t vb = vld1q_f32(b + i);
    float32x4_t diff = vsubq_f32(va, vb);
    vsum = vmlaq_f32(vsum, diff, diff);
  }
  sum = vaddvq_f32(vsum);
#elif defined(HAS_AVX2)
  __m256 vsum = _mm256_setzero_ps();
  for (; i <= dim - 8; i += 8) {
    __m256 va = _mm256_loadu_ps(a + i);
    __m256 vb = _mm256_loadu_ps(b + i);
    __m256 diff = _mm256_sub_ps(va, vb);
    vsum = _mm256_fmadd_ps(diff, diff, vsum);
  }
  float buffer[8];
  _mm256_storeu_ps(buffer, vsum);
  for (int j = 0; j < 8; j++) sum += buffer[j];
#endif

  // Scalar tail
  for (; i < dim; i++) {
    float diff = a[i] - b[i];
    sum += diff * diff;
  }
  return sum;
}

float corbel_simd_cosine(const float* a, const float* b, int dim) {
  int i = 0;
  float dot = 0.0f;
  float normA = 0.0f;
  float normB = 0.0f;

  for (; i < dim; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  if (normA <= 0.0f || normB <= 0.0f) return 0.0f;
  return dot / (sqrtf(normA) * sqrtf(normB));
}

float corbel_simd_manhattan(const float* a, const float* b, int dim) {
  float sum = 0.0f;
  for (int i = 0; i < dim; i++) {
    sum += fabsf(a[i] - b[i]);
  }
  return sum;
}

void corbel_simd_batch_dot_product(
    const float* query,
    const float* matrix,
    float* results,
    int count,
    int dim
) {
  for (int i = 0; i < count; i++) {
    results[i] = corbel_simd_dot_product(query, matrix + (i * dim), dim);
  }
}
