/*
Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
*/
/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "core/providers/cuda/cu_inc/common.cuh"
#include "contrib_ops/cuda/bert/relative_attn_bias_impl.h"

namespace onnxruntime {
namespace contrib {
namespace cuda {

using namespace onnxruntime::cuda;

template<typename T>
__global__ void buildRelativeAttentionBias(T* relative_attention_bias,
                                           const T* relative_attention_bias_table,
                                           const int head_num,
                                           const int seq_len,
                                           const int num_bucket,
                                           const bool is_bidirectional,
                                           const int max_distance) {
  const int head_id = blockIdx.x;
  for (int seq_id = blockDim.x * blockIdx.y + threadIdx.x; seq_id < seq_len * seq_len; seq_id += blockDim.x * gridDim.y) {
    int row_id = seq_id / seq_len;
    int col_id = seq_id % seq_len;

    int relative_position = col_id - row_id;

    int relative_buckets = 0;
    int tmp_num_bucket = num_bucket;

    if (is_bidirectional) {
        tmp_num_bucket /= 2;
        if (relative_position > 0) {
            relative_buckets += tmp_num_bucket;
        } else {
            relative_position *= -1;
        }
    } else {
        if (relative_position > 0) {
            relative_position = 0;
        } else {
            relative_position *= -1;
        }
    }

    int max_exact = tmp_num_bucket / 2;
    bool is_small  = relative_position < max_exact;

    int relative_position_if_large =
        max_exact
        + (int)(logf(relative_position * 1.0f / max_exact) / logf((float)max_distance / max_exact)
                * (tmp_num_bucket - max_exact));

    relative_position_if_large = min(relative_position_if_large, tmp_num_bucket - 1);

    relative_buckets += is_small ? relative_position : relative_position_if_large;

    relative_attention_bias[head_id * seq_len * seq_len + seq_id] =
        relative_attention_bias_table[head_id * num_bucket + relative_buckets];
    }
}

template <typename T>
Status LaunchRelPosAttnBiasKernel(
  cudaStream_t stream,
  T* output,
  const T* bias_table,
  const int num_heads,
  const int seq_len,
  const int num_bucket,
  const int max_distance,
  const bool is_bidirectional,
  const int max_threads_per_block)
{
  const int squared_sq_len = seq_len * seq_len;
  if (squared_sq_len <= max_threads_per_block) {
    dim3 grid(num_heads);
    dim3 block(squared_sq_len);
    buildRelativeAttentionBias<<<grid, block, 0, stream>>>(output,
                                                           bias_table,
                                                           num_heads,
                                                           seq_len,
                                                           num_bucket,
                                                           is_bidirectional,
                                                           max_distance);
    return CUDA_CALL(cudaGetLastError());
  } else if (seq_len >= 128 && seq_len <= 384) {
    dim3 grid(num_heads, seq_len);
    dim3 block(seq_len);
    buildRelativeAttentionBias<<<grid, block, 0, stream>>>(output,
                                                           bias_table,
                                                           num_heads,
                                                           seq_len,
                                                           num_bucket,
                                                           is_bidirectional,
                                                           max_distance);
    return CUDA_CALL(cudaGetLastError());
  } else {
    int blockSize = max_threads_per_block;
    const int grid_y_Size = (squared_sq_len + blockSize - 1) / blockSize;
    dim3 grid(num_heads, grid_y_Size);
    dim3 block(blockSize);
    buildRelativeAttentionBias<<<grid, block, 0, stream>>>(output,
                                                           bias_table,
                                                           num_heads,
                                                           seq_len,
                                                           num_bucket,
                                                           is_bidirectional,
                                                           max_distance);

    return CUDA_CALL(cudaGetLastError());
  }
}

template Status LaunchRelPosAttnBiasKernel<float>(cudaStream_t stream,
                                                  float* output,
                                                  const float* bias_table,
                                                  const int num_heads,
                                                  const int seq_len,
                                                  const int num_bucket,
                                                  const int max_distance,
                                                  const bool is_bidirectional,
                                                  const int max_threads_per_block);

template Status LaunchRelPosAttnBiasKernel<half>(cudaStream_t stream,
                                                 half* output,
                                                 const half* bias_table,
                                                 const int num_heads,
                                                 const int seq_len,
                                                 const int num_bucket,
                                                 const int max_distance,
                                                 const bool is_bidirectional,
                                                 const int max_threads_per_block);

template <typename T>
__global__ void GatedRelativePositionBiasKernelSmallD(
    T* output,         // (batch_size, num_heads, seq_len, seq_len)
    const T* rel_pos,  // (1, num_heads, seq_len, seq_len)
    const T* qw,       // (batch_size, num_heads, seq_len, D)
    const T* bias,     // (D)
    const T* eco_a,    // (1, num_heads, 1, 1)
    const int D,
    const int ldqw) {
  __shared__ float gate[1];

  const int seq_len = gridDim.x;
  const int num_heads = gridDim.y;
  const int s = blockIdx.x;
  const int n = blockIdx.y;
  const int b = blockIdx.z;

  rel_pos += ((int64_t)n * seq_len + s) * seq_len;
  output += ((int64_t)b * num_heads * seq_len + (int64_t)n * seq_len + s) * seq_len;
  qw += ((int64_t)b * num_heads * seq_len + (int64_t)n * seq_len + s) * ldqw;

  float val = 0.0f;
  if (threadIdx.x < D) {
    val = (float)qw[threadIdx.x] + (bias ? (float)bias[threadIdx.x] : 0.0f);
  }

  float u = (threadIdx.x < D / 2) ? val : 0.0f;
#pragma unroll
  for (int offset = 16; offset > 0; offset /= 2) {
    u += __shfl_down_sync(0xffffffff, u, offset);
  }

  float r = (threadIdx.x >= D / 2) ? val : 0.0f;
#pragma unroll
  for (int offset = 16; offset > 0; offset /= 2) {
    r += __shfl_down_sync(0xffffffff, r, offset);
  }

  if (threadIdx.x == 0) {
    u = 1.0f / (1.0f + expf(-u));
    r = 1.0f / (1.0f + expf(-r));
    gate[0] = u * (r * (float)eco_a[n] - 1.0f) + 2.0f;
  }
  __syncthreads();

  for (int idx = threadIdx.x; idx < seq_len; idx += blockDim.x) {
    output[idx] = (T)(gate[0]  * (float)rel_pos[idx]);
  }
}

template <typename T>
Status LaunchGatedRelativePositionBiasKernel(
    const cudaDeviceProp& device_prop,
    cudaStream_t stream,
    T* output,
    const T* rel_pos,
    const T* qw,  // query * weight
    const T* bias,
    const T* eco_a,
    const int batch_size,
    const int num_heads,
    const int seq_len,
    const int D,
    const int ldqw) {
  ORT_ENFORCE(D <= 32 && D > 0 && (D % 2 == 0));
  ORT_ENFORCE(ldqw == seq_len || ldqw == D);

  int tpb = std::max(32, std::max(D, seq_len));
  tpb = std::min(tpb, device_prop.maxThreadsPerBlock);

  // round up tpb to power of 2
  --tpb;
  tpb |= (tpb >> 1);
  tpb |= (tpb >> 2);
  tpb |= (tpb >> 4);
  tpb |= (tpb >> 8);
  tpb |= (tpb >> 16);
  tpb++;

  dim3 block(tpb);
  dim3 grid(seq_len, num_heads, batch_size);

  GatedRelativePositionBiasKernelSmallD<<<grid, block, sizeof(float), stream>>>(
      output, rel_pos, qw, bias, eco_a, D, ldqw);

  return CUDA_CALL(cudaGetLastError());
}

template Status LaunchGatedRelativePositionBiasKernel(
    const cudaDeviceProp& device_prop,
    cudaStream_t stream,
    float* output,
    const float* rel_pos,
    const float* qw,
    const float* bias,
    const float* eco_a,
    const int batch_size,
    const int num_heads,
    const int seq_len,
    const int D,
    const int ldqw);

template Status LaunchGatedRelativePositionBiasKernel(
    const cudaDeviceProp& device_prop,
    cudaStream_t stream,
    half* output,
    const half* rel_pos,
    const half* qw,
    const half* bias,
    const half* eco_a,
    const int batch_size,
    const int num_heads,
    const int seq_len,
    const int D,
    const int ldqw);

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime
