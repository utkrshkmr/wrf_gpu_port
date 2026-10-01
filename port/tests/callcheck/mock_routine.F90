! A ported routine in the form of the port (route R_CALC_ALT, one kernel),
! used by T-CALLCHECK (port/tests/callcheck).  make_mock.py inserts the
! island that port/tools/gen_island.py generates for it at the two markers.
! With -DMOCK_BUG the kernel computes one value differently while the route
! runs on the device (gpu_on true), as a porting mistake would.
MODULE mock_m
   USE module_gpu_route, ONLY : gpu_on, gpu_island, gpu_world_host, R_CALC_ALT
!ISLAND-USE
   IMPLICIT NONE
CONTAINS
   SUBROUTINE calc_alt(alt, al, alb, ncall, ims, ime, kms, kme, jms, jme, its, ite, kts, kte, jts, jte)
      INTEGER, INTENT(IN) :: ims, ime, kms, kme, jms, jme, its, ite, kts, kte, jts, jte
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: al, alb
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: alt
      INTEGER, INTENT(INOUT) :: ncall
      INTEGER :: i, k, j
      LOGICAL :: bug
#ifdef WRF_GPU
      LOGICAL :: gpu_isl
#endif
!ISLAND-ENTRY
      bug = .FALSE.
#ifdef MOCK_BUG
      bug = gpu_on(R_CALC_ALT)
#endif
      ncall = ncall + 1
!$omp target teams distribute parallel do collapse(3) if(target: gpu_on(R_CALC_ALT)) default(none) &
!$omp& shared(alt, al, alb) firstprivate(its, ite, kts, kte, jts, jte, bug)
      DO j = jts, jte
         DO k = kts, kte
            DO i = its, ite
               alt(i, k, j) = al(i, k, j) + alb(i, k, j)
               IF (bug .AND. i == its + 1 .AND. k == kts + 2 .AND. j == jts + 3) alt(i, k, j) = 1.5*alt(i, k, j)
            END DO
         END DO
      END DO
!ISLAND-EXIT
   END SUBROUTINE calc_alt
END MODULE mock_m
