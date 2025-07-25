// bitnet_kernel_wasm.wgsl
// BitNet B1.58 Ternary Kernel for WASM/WebGPU (Browser-Optimized)
// - Designed for maximum compatibility and performance in browsers (Chrome, Firefox, Edge, Safari)
// - Uses tiling, shared memory, and vectorization
// - Avoids array returns from functions (for browser and future DX12 compatibility)
// - No device-specific hacks, just clean, modern WGSL

struct BitnetMetadata {
    M: u32,           // Batch size
    N: u32,           // Output features
    K: u32,           // Input features
    K_packed: u32,    // K / 16 (since we pack 16 weights per u32)
};

@group(0) @binding(0) var<uniform> metadata: BitnetMetadata;
@group(0) @binding(1) var<storage, read> activations: array<i32>;
@group(0) @binding(2) var<storage, read> packed_weights: array<u32>;
@group(0) @binding(3) var<storage, read> weight_scales: array<f32>;
@group(0) @binding(4) var<storage, read> activation_scales: array<f32>; // Per-batch activation scales
@group(0) @binding(5) var<storage, read_write> output: array<f32>;

// Tiling parameters (tuned for browser GPUs)
const TILE_DIM_M: u32 = 32u;   // Smaller tiles for browser GPUs
const TILE_DIM_N: u32 = 32u;
const TILE_DIM_K: u32 = 16u;

const THREAD_TILE_M: u32 = 2u;
const THREAD_TILE_N: u32 = 2u;

const WORKGROUP_SIZE_X: u32 = 16u; // TILE_DIM_N / THREAD_TILE_N
const WORKGROUP_SIZE_Y: u32 = 16u; // TILE_DIM_M / THREAD_TILE_M

// Shared memory tiles
const TILE_A_SIZE: u32 = (TILE_DIM_M * TILE_DIM_K) / 4u; // for vec4<i32>
const TILE_B_SIZE: u32 = TILE_DIM_K * TILE_DIM_N;         // for i32
var<workgroup> tile_a: array<vec4<i32>, TILE_A_SIZE>;
var<workgroup> tile_b: array<i32, TILE_B_SIZE>;

// Decode a single 2-bit ternary value
fn decode_2bit(val: u32) -> i32 {
    switch(val) {
        case 1u: { return 1; }   // 01
        case 2u: { return -1; }  // 10
        default: { return 0; }   // 00 or 11
    }
}

// Vectorized dot product
fn dot_product_4x4(a: vec4<i32>, b: vec4<i32>) -> i32 {
    return dot(a, b);
}

@compute @workgroup_size(WORKGROUP_SIZE_X, WORKGROUP_SIZE_Y, 1)
fn main(
    @builtin(workgroup_id) workgroup_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(local_invocation_index) local_index: u32
) {
    let thread_idx_m = local_id.y;
    let thread_idx_n = local_id.x;
    let tile_start_m = workgroup_id.y * TILE_DIM_M;
    let tile_start_n = workgroup_id.x * TILE_DIM_N;

    // Accumulator for this thread's tile
    var accumulators: array<i32, 4>; // 2x2 tile
    for (var i = 0u; i < 4u; i = i + 1u) {
        accumulators[i] = 0;
    }

    // Main tiling loop
    let num_k_tiles = (metadata.K + TILE_DIM_K - 1u) / TILE_DIM_K;
    var k_tile_idx = 0u;
    while (k_tile_idx < num_k_tiles) {
        let k_tile_start = k_tile_idx * TILE_DIM_K;

        // --- Cooperative loading: Activations ---
        let total_a_elements = TILE_DIM_M * TILE_DIM_K / 4u;
        let loads_per_thread_a = (total_a_elements + 255u) / 256u;
        for (var i = 0u; i < loads_per_thread_a; i = i + 1u) {
            let load_idx = i * 256u + local_index;
            if (load_idx < total_a_elements) {
                let vec_idx = load_idx;
                let flat_idx = load_idx * 4u;
                let m = flat_idx / TILE_DIM_K;
                let k = flat_idx % TILE_DIM_K;
                let global_m = tile_start_m + m;
                let global_k = k_tile_start + k;
                if (global_m < metadata.M && global_k + 3u < metadata.K) {
                    let base_addr = global_m * metadata.K + global_k;
                    tile_a[vec_idx] = vec4<i32>(
                        activations[base_addr],
                        activations[base_addr + 1u],
                        activations[base_addr + 2u],
                        activations[base_addr + 3u]
                    );
                } else {
                    tile_a[vec_idx] = vec4<i32>(0);
                }
            }
        }

        // --- Cooperative loading: Weights (decode in-place) ---
        let total_b_elements = TILE_DIM_N * TILE_DIM_K;
        let loads_per_thread_b = (total_b_elements + 255u) / 256u;
        for (var i = 0u; i < loads_per_thread_b; i = i + 1u) {
            let load_idx = i * 256u + local_index;
            if (load_idx < total_b_elements && (load_idx % 16u) == 0u) {
                let n = load_idx / TILE_DIM_K;
                let k = load_idx % TILE_DIM_K;
                let global_n = tile_start_n + n;
                let global_k_packed_idx = (k_tile_start + k) / 16u;
                if (global_n < metadata.N && global_k_packed_idx < metadata.K_packed) {
                    let weight_idx = global_n * metadata.K_packed + global_k_packed_idx;
                    let packed_w = packed_weights[weight_idx];
                    // Unroll decode for 16 weights
                    tile_b[n * TILE_DIM_K + k + 0u] = decode_2bit((packed_w >> 0u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 1u] = decode_2bit((packed_w >> 2u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 2u] = decode_2bit((packed_w >> 4u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 3u] = decode_2bit((packed_w >> 6u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 4u] = decode_2bit((packed_w >> 8u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 5u] = decode_2bit((packed_w >> 10u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 6u] = decode_2bit((packed_w >> 12u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 7u] = decode_2bit((packed_w >> 14u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 8u] = decode_2bit((packed_w >> 16u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 9u] = decode_2bit((packed_w >> 18u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 10u] = decode_2bit((packed_w >> 20u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 11u] = decode_2bit((packed_w >> 22u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 12u] = decode_2bit((packed_w >> 24u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 13u] = decode_2bit((packed_w >> 26u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 14u] = decode_2bit((packed_w >> 28u) & 0x3u);
                    tile_b[n * TILE_DIM_K + k + 15u] = decode_2bit((packed_w >> 30u) & 0x3u);
                } else {
                    for (var j = 0u; j < 16u; j = j + 1u) {
                        tile_b[n * TILE_DIM_K + k + j] = 0;
                    }
                }
            }
        }

        workgroupBarrier();

        // --- Vectorized computation ---
        for (var k_inner = 0u; k_inner < TILE_DIM_K; k_inner = k_inner + 4u) {
            var a_vecs: array<vec4<i32>, THREAD_TILE_M>;
            for (var m = 0u; m < THREAD_TILE_M; m = m + 1u) {
                let base_m = thread_idx_m * THREAD_TILE_M + m;
                let vec_idx = (base_m * TILE_DIM_K + k_inner) / 4u;
                a_vecs[m] = tile_a[vec_idx];
            }
            for (var n = 0u; n < THREAD_TILE_N; n = n + 1u) {
                let base_n = thread_idx_n * THREAD_TILE_N + n;
                let b_vec = vec4<i32>(
                    tile_b[base_n * TILE_DIM_K + k_inner],
                    tile_b[base_n * TILE_DIM_K + k_inner + 1u],
                    tile_b[base_n * TILE_DIM_K + k_inner + 2u],
                    tile_b[base_n * TILE_DIM_K + k_inner + 3u]
                );
                for (var m = 0u; m < THREAD_TILE_M; m = m + 1u) {
                    let acc_idx = m * THREAD_TILE_N + n;
                    accumulators[acc_idx] += dot_product_4x4(a_vecs[m], b_vec);
                }
            }
        }
        workgroupBarrier();
        k_tile_idx = k_tile_idx + 1u;
    }

    // --- Write results with scaling ---
    for (var m = 0u; m < THREAD_TILE_M; m = m + 1u) {
        for (var n = 0u; n < THREAD_TILE_N; n = n + 1u) {
            let global_m = tile_start_m + thread_idx_m * THREAD_TILE_M + m;
            let global_n = tile_start_n + thread_idx_n * THREAD_TILE_N + n;
            if (global_m < metadata.M && global_n < metadata.N) {
                let activation_scale = activation_scales[global_m];
                let weight_scale = weight_scales[global_n];
                let acc_idx = m * THREAD_TILE_N + n;
                let final_result = f32(accumulators[acc_idx]) * activation_scale * weight_scale;
                output[global_m * metadata.N + global_n] = final_result;
            }
        }
    }
} 