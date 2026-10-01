/*
   gpu_col.h -- GPU port: fixed sizes for the column-physics kernels
   (plan.md 8.0 CP-3; port/agent/PHASE3.md P3.0; tested example:
   port/tests/templates/t_tmpl_cp.F90).

   A column kernel calls a physics core for ONE column (its=ite=1, kts=1,
   kte=nz).  In the GPU view the automatic arrays of the core, sized by the
   tile in the source, get fixed bounds so that they live in the stack frame
   of the thread (never on the device heap).  Write each such declaration
   twice, the original line unchanged in the #else branch (arith_guard
   compares the CPU view text; it does not expand macros):

     #ifdef WRF_GPU
           real, dimension(GPU_IK) :: qs, work
     #else
           real, dimension(its:ite,kts:kte) :: qs, work
     #endif

     GPU_I       for (its:ite)              is (1:1)
     GPU_K       for (kts:kte)              is (1:WRF_KMAX)
     GPU_K1      for (kts:kte+1)            is (1:WRF_KMAX+1)
     GPU_IK      for (its:ite,kts:kte)      is (1:1,1:WRF_KMAX)
     GPU_IK1     for (its:ite,kts:kte+1)    is (1:1,1:WRF_KMAX+1)
     GPU_IKN(n)  for (its:ite,kts:kte,n)    is (1:1,1:WRF_KMAX,1:n)
     GPU_L       RRTMG layers (1:nlayers)   is (1:WRF_NLAYMAX)
     GPU_L1      RRTMG levels (0:nlayers)   is (0:WRF_NLAYMAX)
     GPU_S       Noah soil (1:nsoil)        is (1:WRF_NSOILMAX)

   These arrays are LONGER than the active column.  In the GPU view every
   whole-array statement on them (x = 0., x(:,:) = y(:,:), SIZE(x),
   SUM(x), MAXVAL(x)) becomes an explicit section x(its:ite,kts:kte).  Dummies
   of the core that are assumed-shape (dimension(its:,:)) receive the
   active size from the sections the wrapper passes: x_col(1:1,1:nz).

   gpu_check_config (P1.8) stops a run with e_vert-1 > WRF_KMAX or an RRTMG
   NLAYERS > WRF_NLAYMAX.  Include this file inside #ifdef WRF_GPU in model
   code (the CPU view must not change); module_gpu_check includes it always.
*/
#ifndef GPU_COL_H
#define GPU_COL_H

#ifndef WRF_KMAX
#define WRF_KMAX 64
#endif
#ifndef WRF_NLAYMAX
#define WRF_NLAYMAX 128
#endif
#ifndef WRF_NSOILMAX
#define WRF_NSOILMAX 4
#endif

#define GPU_I 1:1
#define GPU_K 1:WRF_KMAX
#define GPU_K1 1:WRF_KMAX+1
#define GPU_IK 1:1,1:WRF_KMAX
#define GPU_IK1 1:1,1:WRF_KMAX+1
#define GPU_IKN(n) 1:1,1:WRF_KMAX,1:n
#define GPU_L 1:WRF_NLAYMAX
#define GPU_L1 0:WRF_NLAYMAX
#define GPU_S 1:WRF_NSOILMAX

#endif
