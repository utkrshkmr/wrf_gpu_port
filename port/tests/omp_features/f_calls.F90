! F-CALLS (plan.md P0.5b): a loop that calls a declare-target routine, as
! "target teams loop" and as "target teams distribute parallel do".
! Check the -Minfo=mp output in the build log: both loops must be
! parallelized over teams and threads.
MODULE f_calls_m
CONTAINS
   SUBROUTINE work(x, y)
!$omp declare target
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: y
      y = x*2.0 + 1.0
   END SUBROUTINE work
END MODULE f_calls_m

PROGRAM f_calls
   USE f_calls_m
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 1000000
   REAL, ALLOCATABLE :: x(:), y1(:), y2(:)
   INTEGER :: i
   DOUBLE PRECISION :: t0, t1, t2
   ALLOCATE (x(n), y1(n), y2(n))
   DO i = 1, n
      x(i) = REAL(i)
   END DO
!$omp target enter data map(to: x) map(alloc: y1, y2)
   t0 = omp_get_wtime()
!$omp target teams loop
   DO i = 1, n
      CALL work(x(i), y1(i))
   END DO
   t1 = omp_get_wtime()
!$omp target teams distribute parallel do
   DO i = 1, n
      CALL work(x(i), y2(i))
   END DO
   t2 = omp_get_wtime()
!$omp target exit data map(from: y1, y2) map(delete: x)
   IF (ALL(y1 == 2.0*x + 1.0) .AND. ALL(y2 == y1)) THEN
      PRINT '(a,2f10.6,a)', 'PROBE F-CALLS PASS (seconds teams-loop, distribute-parallel-do:', t1 - t0, t2 - t1, ')'
   ELSE
      PRINT '(a)', 'PROBE F-CALLS FAIL wrong results'
   END IF
END PROGRAM f_calls
