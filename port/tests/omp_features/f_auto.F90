! F-AUTO (plan.md P0.5b, CP-3): automatic arrays in a declare-target routine
! versus fixed-size locals.  Correctness and time.
MODULE f_auto_m
CONTAINS
   SUBROUTINE colwork_auto(nk, x, r)
!$omp declare target
      INTEGER, INTENT(IN) :: nk
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: r
      REAL :: t(nk)
      INTEGER :: k
      DO k = 1, nk
         t(k) = x + REAL(k)
      END DO
      r = SUM(t)
   END SUBROUTINE colwork_auto
   SUBROUTINE colwork_fixed(nk, x, r)
!$omp declare target
      INTEGER, INTENT(IN) :: nk
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: r
      REAL :: t(64)
      INTEGER :: k
      DO k = 1, nk
         t(k) = x + REAL(k)
      END DO
      r = SUM(t(1:nk))
   END SUBROUTINE colwork_fixed
END MODULE f_auto_m

PROGRAM f_auto
   USE f_auto_m
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 500000
   REAL, ALLOCATABLE :: r1(:), r2(:)
   INTEGER :: i
   DOUBLE PRECISION :: t0, t1, t2
   ALLOCATE (r1(n), r2(n))
   t0 = omp_get_wtime()
!$omp target teams distribute parallel do map(from: r1)
   DO i = 1, n
      CALL colwork_auto(60, REAL(i), r1(i))
   END DO
   t1 = omp_get_wtime()
!$omp target teams distribute parallel do map(from: r2)
   DO i = 1, n
      CALL colwork_fixed(60, REAL(i), r2(i))
   END DO
   t2 = omp_get_wtime()
   IF (ALL(r1 == r2)) THEN
      PRINT '(a,2f10.6,a)', 'PROBE F-AUTO PASS (seconds automatic, fixed:', t1 - t0, t2 - t1, ')'
   ELSE
      PRINT '(a)', 'PROBE F-AUTO FAIL'
   END IF
END PROGRAM f_auto
