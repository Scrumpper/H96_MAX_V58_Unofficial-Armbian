// npuload.c — generate a genuine RK3588 NPU load via the RKNN matmul API.
// No model file needed: an INT8 M×K×N matmul is the NPU's native workload.
// This resumes the NPU power domain the CORRECT way (a real submission), so
// /proc/rknpu/power flips off->on on its own and per-core load climbs.
//
// Usage: npuload [iters] [core]
//   iters : matmul iterations           (default 3000)
//   core  : auto | 0 | 1 | 2 | all      (default all)
//     0/1/2 pins the job to that single core (mask 1/2/4). This is the only
//     way to spread work across cores for a raw (non-compiled) matmul: RKNN
//     rejects a 3-core mask unless the MODEL was built multi-core offline, and
//     'auto' packs onto core 0. Pin one job per core to use the whole NPU.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "rknn_api.h"
#include "rknn_matmul_api.h"

static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char** argv) {
    int iters = (argc > 1) ? atoi(argv[1]) : 3000;
    const char* core = (argc > 2) ? argv[2] : "all";

    int mask;
    if      (!strcmp(core, "auto")) mask = RKNN_NPU_CORE_AUTO;
    else if (!strcmp(core, "0"))    mask = RKNN_NPU_CORE_0;
    else if (!strcmp(core, "1"))    mask = RKNN_NPU_CORE_1;
    else if (!strcmp(core, "2"))    mask = RKNN_NPU_CORE_2;
    else                            mask = RKNN_NPU_CORE_0_1_2;  // "all"

    rknn_matmul_info info; memset(&info, 0, sizeof(info));
    info.M = 256; info.K = 4096; info.N = 4096;        // all 32-byte aligned for RK3588 int8
    info.type = RKNN_INT8_MM_INT8_TO_INT32;
    info.B_layout = 0; info.AC_layout = 0;

    rknn_matmul_io_attr io; memset(&io, 0, sizeof(io));
    rknn_matmul_ctx ctx = 0;
    int ret = rknn_matmul_create(&ctx, &info, &io);
    if (ret != 0) { fprintf(stderr, "rknn_matmul_create failed: %d\n", ret); return 1; }

    // Pin to the requested core(s). Skip the call for 'auto' so the runtime is
    // left to schedule (and so a single-core run makes no failing 3-core call).
    if (mask != RKNN_NPU_CORE_AUTO) {
        ret = rknn_matmul_set_core_mask(ctx, mask);
        if (ret != 0) fprintf(stderr, "warn: set_core_mask(%s) ret %d (continuing on auto)\n", core, ret);
    }

    rknn_tensor_mem* A = rknn_create_mem(ctx, io.A.size);
    rknn_tensor_mem* B = rknn_create_mem(ctx, io.B.size);
    rknn_tensor_mem* C = rknn_create_mem(ctx, io.C.size);
    if (!A || !B || !C) { fprintf(stderr, "alloc failed (A=%p B=%p C=%p)\n",(void*)A,(void*)B,(void*)C); return 1; }
    memset(A->virt_addr, 1, io.A.size);
    memset(B->virt_addr, 1, io.B.size);

    if (rknn_matmul_set_io_mem(ctx, A, &io.A) ||
        rknn_matmul_set_io_mem(ctx, B, &io.B) ||
        rknn_matmul_set_io_mem(ctx, C, &io.C)) {
        fprintf(stderr, "set_io_mem failed\n"); return 1;
    }

    printf("matmul %dx%dx%d int8, %d iters, core %s\n", info.M, info.K, info.N, iters, core);
    printf("A=%u B=%u C=%u bytes\n", io.A.size, io.B.size, io.C.size);
    fflush(stdout);

    // warmup (first run triggers the power-domain resume)
    if ((ret = rknn_matmul_run(ctx)) != 0) { fprintf(stderr, "run failed: %d\n", ret); return 1; }

    double t0 = now_s();
    for (int i = 0; i < iters; i++) {
        if ((ret = rknn_matmul_run(ctx)) != 0) { fprintf(stderr, "run %d failed: %d\n", i, ret); return 1; }
        if ((i & 255) == 255) { printf("  %d/%d\n", i + 1, iters); fflush(stdout); }
    }
    double dt = now_s() - t0;

    double ops = 2.0 * info.M * info.K * info.N * iters;   // 2 = mul+add per MAC
    printf("done: %d matmuls in %.2fs  =>  %.2f ms/run, %.1f GOPS\n",
           iters, dt, 1000.0 * dt / iters, ops / dt / 1e9);

    rknn_destroy_mem(ctx, A); rknn_destroy_mem(ctx, B); rknn_destroy_mem(ctx, C);
    rknn_matmul_destroy(ctx);
    return 0;
}
