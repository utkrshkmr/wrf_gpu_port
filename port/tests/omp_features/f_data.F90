! F-DATA (plan.md 8.5; port/agent/PHASE3.md "Shared refactors"): a local
! array initialized by DATA (implicitly SAVE) inside a declare target routine,
! as ALBTAB/ABSTAB/XMUVAL in SWPARA (module_ra_sw.F).  PASS: such tables can
! stay.  FAIL or a build failure: convert them to PARAMETER arrays (a shared
! refactor, WORKFLOW.md section 6) before porting the routine.
MODULE f_data_m
   IMPLICIT NONE
CONTAINS
   SUBROUTINE use_data(i, r)
!$omp declare target
      INTEGER, INTENT(IN) :: i
      REAL, INTENT(OUT) :: r
      REAL :: tab(4)
      DATA tab/0.125, 0.25, 0.375, 0.5/
      r = tab(MOD(i, 4) + 1) + REAL(i)
   END SUBROUTINE use_data
END MODULE f_data_m

PROGRAM f_data
   USE f_data_m
   USE omp_lib
   IMPLICIT NONE
   REAL :: rd(1000), hd(1000)
   INTEGER :: i
   LOGICAL :: on_host
   on_host = .TRUE.
!$omp target map(from: on_host)
   on_host = omp_is_initial_device()
!$omp end target
   IF (on_host) THEN
      PRINT '(a)', 'PROBE F-DATA SKIP (no device)'
      STOP
   END IF
!$omp target teams distribute parallel do map(from: rd)
   DO i = 1, 1000
      CALL use_data(i, rd(i))
   END DO
   DO i = 1, 1000
      CALL use_data(i, hd(i))
   END DO
   IF (ALL(rd == hd)) THEN
      PRINT '(a)', 'PROBE F-DATA PASS (DATA-initialized local tables usable in device routines)'
   ELSE
      PRINT '(a)', 'PROBE F-DATA FAIL (convert DATA tables to PARAMETER arrays before porting the routine)'
   END IF
END PROGRAM f_data
