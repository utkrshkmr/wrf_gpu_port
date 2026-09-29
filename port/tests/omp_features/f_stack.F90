! F-STACK (plan.md P0.5b, CP-5): a kernel whose threads need a large stack
! frame (32 KB of fixed-size locals, like WSM6 after CP-3).  Reports the CUDA
! stack limit before and after, read through the C shim (stack_shim.c), and
! whether NV_ACC_CUDA_STACKSIZE changed it.
MODULE f_stack_m
CONTAINS
   SUBROUTINE big(i, r)
!$omp declare target
      INTEGER, INTENT(IN) :: i
      REAL, INTENT(OUT) :: r
      REAL :: w(8192)
      INTEGER :: k
      DO k = 1, 8192
         w(k) = REAL(MOD(i + k, 97))
      END DO
      r = SUM(w)
   END SUBROUTINE big
END MODULE f_stack_m

PROGRAM f_stack
   USE f_stack_m
   USE iso_c_binding
   IMPLICIT NONE
   INTERFACE
      INTEGER(C_INT) FUNCTION wrf_cuda_stack_limit(sz) BIND(C, NAME='wrf_cuda_stack_limit')
         IMPORT :: C_INT, C_SIZE_T
         INTEGER(C_SIZE_T), INTENT(OUT) :: sz
      END FUNCTION wrf_cuda_stack_limit
   END INTERFACE
   INTEGER, PARAMETER :: n = 100000
   REAL :: r(n), h(n)
   INTEGER(C_SIZE_T) :: before, after
   INTEGER :: i, rc
   rc = wrf_cuda_stack_limit(before)
!$omp target teams distribute parallel do map(from: r)
   DO i = 1, n
      CALL big(i, r(i))
   END DO
   rc = wrf_cuda_stack_limit(after)
   DO i = 1, n
      CALL big(i, h(i))
   END DO
   IF (ALL(r == h)) THEN
      PRINT '(a,i0,a,i0,a)', 'PROBE F-STACK PASS (CUDA stack limit before=', before, ' after=', after, ' bytes)'
   ELSE
      PRINT '(a)', 'PROBE F-STACK FAIL'
   END IF
END PROGRAM f_stack
