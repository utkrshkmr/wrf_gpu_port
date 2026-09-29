/* CUDA stack-limit query for f_stack.F90 (plan.md P0.5b F-STACK, CP-5). */
#include <stddef.h>
#ifdef HAVE_CUDA
#include <cuda_runtime.h>
int wrf_cuda_stack_limit(size_t *sz) {
  return (int)cudaDeviceGetLimit(sz, cudaLimitStackSize);
}
#else
int wrf_cuda_stack_limit(size_t *sz) { *sz = 0; return -1; }
#endif
