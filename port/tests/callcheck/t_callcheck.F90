! T-CALLCHECK driver (port/tests/callcheck/run_callcheck.sh): three calls of
! the mock routine with WRF_GPU_CALLCHECK=calc_alt:2 set by the runner.
PROGRAM t_callcheck
   USE module_gpu_route, ONLY : gpu_route_init
   USE mock_m
   IMPLICIT NONE
   INTEGER, PARAMETER :: ims = -2, ime = 20, kms = 1, kme = 11, jms = -2, jme = 15
   REAL :: alt(ims:ime, kms:kme, jms:jme), al(ims:ime, kms:kme, jms:jme), alb(ims:ime, kms:kme, jms:jme)
   INTEGER :: ncall, c
   CALL gpu_route_init()
   CALL RANDOM_NUMBER(al)
   CALL RANDOM_NUMBER(alb)
   alt = -1.
   ! the state is mapped once, as allocs.inc does in wrf.exe (P1.2)
!$omp target enter data map(to: alt, al, alb)
   ncall = 0
   DO c = 1, 3
      CALL calc_alt(alt, al, alb, ncall, ims, ime, kms, kme, jms, jme, 1, 18, 1, 10, 1, 12)
   END DO
   PRINT '(a,i0)', 'ncall=', ncall
END PROGRAM t_callcheck
