! F-EQUIV (plan.md 8.5; port/agent/PHASE3.md "Shared refactors"): module
! arrays joined by EQUIVALENCE, as in the RRTMG LW tables (module rrlw_kg01:
! equivalence (ka(1,1,1),absa(1,1))): the init fills ka on the host, the
! device reads absa (taugb1).  Both names are declare target; the host updates
! ka, a kernel reads absa, and the other way round.
! PASS: the device sees the same storage under both names.  FAIL or a BUILD
! FAILURE (gfortran 13 rejects it: "EQUIVALENCE attribute conflicts with OMP
! DECLARE TARGET attribute"; OpenMP does not allow it): the flattening of the
! rrlw_kg* tables into 1D arrays (plan.md P0.9a item 6) is required before
! RRTMG runs on the device.
MODULE f_equiv_m
   IMPLICIT NONE
   INTEGER, PARAMETER :: no = 16
   REAL :: ka(5, 13, no), absa(65, no)
   EQUIVALENCE (ka(1, 1, 1), absa(1, 1))
!$omp declare target(ka, absa)
CONTAINS
   SUBROUTINE read_absa(ind, ig, r)
!$omp declare target
      INTEGER, INTENT(IN) :: ind, ig
      REAL, INTENT(OUT) :: r
      r = absa(ind, ig)
   END SUBROUTINE read_absa
END MODULE f_equiv_m

PROGRAM f_equiv
   USE f_equiv_m
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 65*no
   REAL :: r(n), h(n)
   INTEGER :: i, ig, ind
   LOGICAL :: on_host, ok_eq, ok_eq2
   on_host = .TRUE.
!$omp target map(from: on_host)
   on_host = omp_is_initial_device()
!$omp end target
   IF (on_host) THEN
      PRINT '(a)', 'PROBE F-EQUIV SKIP (no device)'
      STOP
   END IF
   ! the init writes the first name, the device reads the second
   DO ig = 1, no
      DO i = 1, 65
         ka(MOD(i - 1, 5) + 1, (i - 1)/5 + 1, ig) = REAL(i) + 100.*REAL(ig)
      END DO
   END DO
!$omp target update to(ka)
!$omp target teams distribute parallel do map(from: r)
   DO i = 1, n
      CALL read_absa(MOD(i - 1, 65) + 1, (i - 1)/65 + 1, r(i))
   END DO
   DO i = 1, n
      ind = MOD(i - 1, 65) + 1; ig = (i - 1)/65 + 1
      h(i) = absa(ind, ig)
   END DO
   ok_eq = ALL(r == h)
   ! and the other way round: update through the second name
   absa = 2.*absa
!$omp target update to(absa)
!$omp target teams distribute parallel do map(from: r)
   DO i = 1, n
      CALL read_absa(MOD(i - 1, 65) + 1, (i - 1)/65 + 1, r(i))
   END DO
   ok_eq2 = ALL(r == 2.*h)
   IF (ok_eq .AND. ok_eq2) THEN
      PRINT '(a)', 'PROBE F-EQUIV PASS (EQUIVALENCEd declare target tables usable on the device)'
   ELSE
      PRINT '(a,2l2,a)', 'PROBE F-EQUIV FAIL update-ka,update-absa=', ok_eq, ok_eq2, &
         ' (flatten the rrlw_kg* tables before porting RRTMG)'
   END IF
END PROGRAM f_equiv
