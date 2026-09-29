!WRF:DRIVER_LAYER:UTIL
!
! module_gpu_scratch: persistent scratch pool for the i1 arrays of solve_em
! (plan.md P1.6; in both builds from Phase 0, P0.9a item 2).
!
! With -DWRF_POOL the generated i1_decl.inc declares every REAL i1 array as a
! CONTIGUOUS pointer, and i1_assoc.inc (included at the start of solve_em)
! reserves the pool and associates each pointer with its own part of it,
! with the same bounds the automatic array had.
!
! The pool is allocated once (and again only if a larger domain needs more
! room) and zero-filled when allocated.  Between calls it keeps its contents,
! so the CPU reference and the GPU build see the same scratch contents at
! every call; with automatic arrays the contents of unwritten scratch would
! be whatever was on the stack.  T-SHARED-POOL / T-UNINIT check that upstream
! never reads scratch before writing it.
!
! Phase 1 adds the device mapping of the pool (target enter data) here.

MODULE module_gpu_scratch

   IMPLICIT NONE
   PRIVATE

   REAL, ALLOCATABLE, TARGET, SAVE, PUBLIC :: gpu_pool(:)
   INTEGER(8), SAVE :: pool_size = 0_8

   PUBLIC :: gpu_scratch_reserve, wrf_pool_round

CONTAINS

   ! n rounded up to a multiple of 16 elements (64-byte alignment of each array)
   PURE INTEGER(8) FUNCTION wrf_pool_round(n)
      INTEGER(8), INTENT(IN) :: n
      wrf_pool_round = ((n + 15_8)/16_8)*16_8
   END FUNCTION wrf_pool_round

   ! Make sure the pool holds at least n elements.
   SUBROUTINE gpu_scratch_reserve(n)
      USE module_wrf_error
      INTEGER(8), INTENT(IN) :: n
      INTEGER :: ierr
      IF (pool_size >= n) RETURN
      IF (ALLOCATED(gpu_pool)) DEALLOCATE (gpu_pool)
      ALLOCATE (gpu_pool(MAX(n, 1_8)), STAT=ierr)
      IF (ierr /= 0) CALL wrf_error_fatal('gpu_scratch_reserve: cannot allocate the i1 scratch pool')
      gpu_pool = 0.0
      pool_size = n
      WRITE (wrf_err_message, '(a,f10.3,a)') 'gpu_scratch: i1 scratch pool of ', &
         REAL(n, 8)*4.0d0/1.0d9, ' GB (zero-filled)'
      CALL wrf_message(TRIM(wrf_err_message))
   END SUBROUTINE gpu_scratch_reserve

END MODULE module_gpu_scratch
