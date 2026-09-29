! F-DECLMOD (plan.md P0.5b): declare target on module scalars, fixed arrays
! and allocatable arrays; target update / enter data of them.
MODULE f_declmod_m
   IMPLICIT NONE
   REAL :: s
   REAL :: fa(100)
   REAL, ALLOCATABLE :: aa(:)
!$omp declare target(s, fa, aa)
CONTAINS
   REAL FUNCTION get(i)
!$omp declare target
      INTEGER, INTENT(IN) :: i
      get = s + fa(i) + aa(i)
   END FUNCTION get
END MODULE f_declmod_m

PROGRAM f_declmod
   USE f_declmod_m
   IMPLICIT NONE
   REAL :: r(100)
   INTEGER :: i
   s = 1.0
   fa = 2.0
   ALLOCATE (aa(100))
   aa = 3.0
!$omp target update to(s, fa)
!$omp target enter data map(to: aa)
!$omp target teams distribute parallel do map(from: r)
   DO i = 1, 100
      r(i) = get(i)
   END DO
   IF (ALL(r == 6.0)) THEN
      PRINT '(a)', 'PROBE F-DECLMOD PASS'
   ELSE
      PRINT '(a,f8.2)', 'PROBE F-DECLMOD FAIL r(1)=', r(1)
   END IF
END PROGRAM f_declmod
