! F-COMPMAP-MEMBER (information only; port/agent/PHASE1.md H0.3): the
! structure-member form of mapping WRF fields, map(to: grid%f) in separate
! enter data directives (one per field, as a naive allocs.inc would do), then
! target update to/from(grid%f) and exit data map(delete: grid%f).  The port
! does NOT use this form (it maps by address, f_compmap.F90 and
! WRF/frame/module_gpu_map.F); the result is recorded in port/ENVIRONMENT.md
! so that nobody switches to it without knowing how the compiler treats it.
! A build failure of this file is a result too ("not supported").
MODULE compmap_member_m
   USE omp_lib
   USE iso_c_binding
   IMPLICIT NONE
   TYPE dom
      INTEGER :: id
      REAL, ALLOCATABLE :: u_2(:,:,:), v_2(:,:,:), t_2(:,:,:), mu_2(:,:)
      REAL, ALLOCATABLE :: moist(:,:,:,:)
   END TYPE dom
CONTAINS
   SUBROUTINE kern_add(a, n1, n2, n3, c)
      INTEGER, INTENT(IN) :: n1, n2, n3
      REAL, INTENT(INOUT) :: a(n1, n2, n3)
      REAL, INTENT(IN) :: c
      INTEGER :: i, k, j
!$omp target teams distribute parallel do collapse(3)
      DO j = 1, n3
         DO k = 1, n2
            DO i = 1, n1
               a(i, k, j) = a(i, k, j) + c
            END DO
         END DO
      END DO
   END SUBROUTINE kern_add
   LOGICAL FUNCTION pr3(a)
      REAL, INTENT(IN), TARGET :: a(:,:,:)
      pr3 = omp_target_is_present(C_LOC(a(1, 1, 1)), omp_get_default_device()) /= 0
   END FUNCTION pr3
END MODULE compmap_member_m

PROGRAM f_compmap_member
   USE compmap_member_m
   IMPLICIT NONE
   INTEGER, PARAMETER :: ims = -4, ime = 45, kms = 1, kme = 31, jms = -4, jme = 37
   INTEGER, PARAMETER :: n1 = ime - ims + 1, n2 = kme - kms + 1, n3 = jme - jms + 1
   TYPE(dom), POINTER :: grid
   LOGICAL :: pres, nocopy, upd, gone
   IF (omp_get_num_devices() < 1) THEN
      PRINT '(a)', 'PROBE F-COMPMAP-MEMBER SKIP (no device)'
      STOP
   END IF
   ALLOCATE (grid)
   ALLOCATE (grid%u_2(ims:ime, kms:kme, jms:jme)); grid%u_2 = 0.
   ALLOCATE (grid%v_2(ims:ime, kms:kme, jms:jme)); grid%v_2 = 0.
   ALLOCATE (grid%t_2(ims:ime, kms:kme, jms:jme)); grid%t_2 = 0.
   ALLOCATE (grid%mu_2(ims:ime, jms:jme)); grid%mu_2 = 0.
   ALLOCATE (grid%moist(ims:ime, kms:kme, jms:jme, 7)); grid%moist = 0.
!$omp target enter data map(to: grid%u_2)
!$omp target enter data map(to: grid%v_2)
!$omp target enter data map(to: grid%t_2)
!$omp target enter data map(to: grid%mu_2)
!$omp target enter data map(to: grid%moist)
   pres = pr3(grid%u_2) .AND. pr3(grid%v_2) .AND. pr3(grid%t_2)
   CALL kern_add(grid%t_2, n1, n2, n3, 5.)
   nocopy = ALL(grid%t_2 == 0.)
!$omp target update from(grid%t_2)
   upd = ALL(grid%t_2 == 5.)
   grid%v_2 = 3.
!$omp target update to(grid%v_2)
   CALL kern_add(grid%v_2, n1, n2, n3, 1.)
!$omp target update from(grid%v_2)
   upd = upd .AND. ALL(grid%v_2 == 4.)
!$omp target exit data map(delete: grid%u_2)
!$omp target exit data map(delete: grid%v_2)
!$omp target exit data map(delete: grid%t_2)
!$omp target exit data map(delete: grid%mu_2)
!$omp target exit data map(delete: grid%moist)
   gone = .NOT. (pr3(grid%u_2) .OR. pr3(grid%v_2) .OR. pr3(grid%t_2))
   IF (pres .AND. nocopy .AND. upd .AND. gone) THEN
      PRINT '(a)', 'PROBE F-COMPMAP-MEMBER PASS (information only; the port maps by address)'
   ELSE
      PRINT '(a,4l2,a)', 'PROBE F-COMPMAP-MEMBER FAIL present,nocopy,updates,released=', pres, nocopy, upd, gone, &
         ' (information only; the port maps by address)'
   END IF
END PROGRAM f_compmap_member
