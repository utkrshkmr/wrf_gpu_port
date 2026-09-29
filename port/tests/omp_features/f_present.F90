! F-PRESENT (plan.md P0.5b, P1.6): a pointer bounds-remapped onto part of a
! mapped pool, passed to an explicit-shape dummy, must be found present on
! the device and used without any copy.  The kernel has no map clause, so an
! array that is not found present would be copied to and from the device;
! the host copy staying unchanged after the kernel shows it was not.
MODULE f_present_m
CONTAINS
   SUBROUTINE kern(a, n1, n2)
      INTEGER, INTENT(IN) :: n1, n2
      REAL, INTENT(INOUT) :: a(n1, n2)
      INTEGER :: i, j
!$omp target teams distribute parallel do collapse(2)
      DO j = 1, n2
         DO i = 1, n1
            a(i, j) = a(i, j) + REAL(i + 10*j)
         END DO
      END DO
   END SUBROUTINE kern
END MODULE f_present_m

PROGRAM f_present
   USE f_present_m
   USE omp_lib
   USE iso_c_binding
   IMPLICIT NONE
   INTEGER, PARAMETER :: n1 = 50, n2 = 40, off = 1000
   REAL, ALLOCATABLE, TARGET :: pool(:)
   REAL, POINTER, CONTIGUOUS :: p(:,:)
   INTEGER :: i, j
   LOGICAL :: pres, ok
   ALLOCATE (pool(10000))
   pool = 0.0
!$omp target enter data map(to: pool)
   p(1:n1, 1:n2) => pool(off + 1:off + n1*n2)
   pres = omp_target_is_present(C_LOC(p(1, 1)), omp_get_default_device()) /= 0
   CALL kern(p, n1, n2)
   ! host copy must be unchanged until the update
   ok = ALL(pool == 0.0)
!$omp target update from(pool)
   DO j = 1, n2
      DO i = 1, n1
         IF (p(i, j) /= REAL(i + 10*j)) ok = .FALSE.
      END DO
   END DO
   IF (pres .AND. ok) THEN
      PRINT '(a)', 'PROBE F-PRESENT PASS'
   ELSE
      PRINT '(a,2l2)', 'PROBE F-PRESENT FAIL present,no-copy-and-correct=', pres, ok
   END IF
END PROGRAM f_present
