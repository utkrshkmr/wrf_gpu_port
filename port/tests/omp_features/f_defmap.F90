! F-DEFMAP (plan.md P0.5b): defaultmap(present) and map(present, alloc:)
! are accepted and work on mapped data.  The companion f_defmap_neg must fail
! at run time (unmapped array under defaultmap(present)).
PROGRAM f_defmap
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 1000
   REAL, ALLOCATABLE :: a(:), b(:)
   INTEGER :: i
   ALLOCATE (a(n), b(n))
   a = 1.0
   b = 0.0
!$omp target enter data map(to: a, b)
!$omp target teams distribute parallel do defaultmap(present: aggregate) defaultmap(present: allocatable)
   DO i = 1, n
      b(i) = a(i) + 1.0
   END DO
!$omp target teams distribute parallel do map(present, alloc: a, b)
   DO i = 1, n
      b(i) = b(i) + a(i)
   END DO
!$omp target update from(b)
   IF (ALL(b == 3.0)) THEN
      PRINT '(a)', 'PROBE F-DEFMAP PASS'
   ELSE
      PRINT '(a)', 'PROBE F-DEFMAP FAIL'
   END IF
END PROGRAM f_defmap
