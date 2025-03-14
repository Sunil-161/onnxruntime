// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#include "core/providers/cuda/cuda_common.h"
#include "contrib_ops/cpu/bert/attention_common.h"

namespace onnxruntime {
namespace contrib {
namespace cuda {

struct DecoderMaskedMultiheadAttentionParams : AttentionParameters {
  int beam_width = 1;

  void* q = nullptr;
  void* q_bias = nullptr;

  void* k = nullptr;
  void* k_bias = nullptr;

  void* v = nullptr;
  void* v_bias = nullptr;

  void* k_cache = nullptr;
  void* v_cache = nullptr;

  void* out = nullptr;

  const int32_t* cache_indir = nullptr;
  const int32_t* mask = nullptr;    // [B, total_sequence_length]
};


template<
    // The type of the inputs. Supported types: float and half.
    typename T,
    // The hidden dimension per head.
    int head_size,
    // The number of threads per key.
    int THREADS_PER_KEY,
    // The number of threads per value.
    int THREADS_PER_VALUE,
    // The number of threads in a threadblock.
    int THREADS_PER_BLOCK>
__global__ void masked_multihead_attention_kernel(DecoderMaskedMultiheadAttentionParams params);

template<typename T, int head_size>
void mmha_launch_kernel(const DecoderMaskedMultiheadAttentionParams& params, cudaStream_t stream);



}  // namespace cuda

}  // namespace contrib
}  // namespace onnxruntime
