! F-DEFMAP negative case: the array is NOT mapped, so defaultmap(present)
! must make this program fail at run time.  run_probes.sh expects a non-zero
! exit status (or no PASS line).
PROGRAM f_defmap_neg
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 1000
   REAL, ALLOCATABLE :: a(:)
   INTEGER :: i
   ALLOCATE (a(n))
   a = 1.0
!$omp target teams distribute parallel do defaultmap(present: allocatable) defaultmap(present: aggregate)
   DO i = 1, n
      a(i) = a(i) + 1.0
   END DO
   PRINT '(a)', 'PROBE F-DEFMAP-NEG reached the end: unmapped data was accepted'
END PROGRAM f_defmap_neg
