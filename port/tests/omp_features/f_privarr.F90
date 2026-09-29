! F-PRIVARR (plan.md P0.5b): private arrays in a kernel, fixed size (the
! plan default) and run-time size (uses the device heap if supported).
PROGRAM f_privarr
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 200000, kmax = 64
   REAL, ALLOCATABLE :: out1(:), out2(:)
   REAL :: col(kmax)
   REAL, ALLOCATABLE :: dcol(:)
   INTEGER :: i, k, nk
   DOUBLE PRECISION :: t0, t1, t2
   nk = 60
   ALLOCATE (out1(n), out2(n))
   t0 = omp_get_wtime()
!$omp target teams distribute parallel do private(col, k) map(from: out1)
   DO i = 1, n
      DO k = 1, kmax
         col(k) = REAL(i + k)
      END DO
      out1(i) = SUM(col(1:nk))
   END DO
   t1 = omp_get_wtime()
!$omp target teams distribute parallel do private(dcol, k) map(from: out2)
   DO i = 1, n
      ALLOCATE (dcol(nk))
      DO k = 1, nk
         dcol(k) = REAL(i + k)
      END DO
      out2(i) = SUM(dcol)
      DEALLOCATE (dcol)
   END DO
   t2 = omp_get_wtime()
   IF (ALL(out1 == out2)) THEN
      PRINT '(a,2f10.6,a)', 'PROBE F-PRIVARR PASS (seconds fixed, runtime-sized:', t1 - t0, t2 - t1, ')'
   ELSE
      PRINT '(a)', 'PROBE F-PRIVARR FAIL'
   END IF
END PROGRAM f_privarr
