! F-STMTFN, F-INTPROC, F-OPT, F-CHAR (plan.md P0.5b, CP-4): language features
! used by the physics schemes, inside code called from a target region.
! Each is its own routine so a compile failure names the feature.
MODULE f_lang_m
   IMPLICIT NONE
CONTAINS
   SUBROUTINE use_stmtfn(x, r)
!$omp declare target
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: r
      REAL :: cpmcal, a
      cpmcal(a) = 1004.5*(1. - MAX(a, 1.e-15)) + MAX(a, 1.e-15)*1846.4
      r = cpmcal(x)
   END SUBROUTINE use_stmtfn

   SUBROUTINE use_intproc(x, r)
!$omp declare target
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: r
      r = twice(x) + 1.0
   CONTAINS
      REAL FUNCTION twice(y)
         REAL, INTENT(IN) :: y
         twice = 2.0*y
      END FUNCTION twice
   END SUBROUTINE use_intproc

   SUBROUTINE use_opt(x, r, add)
!$omp declare target
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: r
      REAL, INTENT(IN), OPTIONAL :: add
      r = x
      IF (PRESENT(add)) r = r + add
   END SUBROUTINE use_opt

   SUBROUTINE use_char(x, r, tag)
!$omp declare target
      REAL, INTENT(IN) :: x
      REAL, INTENT(OUT) :: r
      CHARACTER(LEN=*), INTENT(IN) :: tag
      IF (tag(1:4) == 'USGS') THEN
         r = x + 1.0
      ELSE
         r = x
      END IF
   END SUBROUTINE use_char
END MODULE f_lang_m

PROGRAM f_langfeat
   USE f_lang_m
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 1000
   REAL :: r(4, n), h(4, n)
   INTEGER :: i
!$omp target teams distribute parallel do map(from: r)
   DO i = 1, n
      CALL use_stmtfn(REAL(i)*1.e-3, r(1, i))
      CALL use_intproc(REAL(i), r(2, i))
      CALL use_opt(REAL(i), r(3, i), 0.5)
      CALL use_char(REAL(i), r(4, i), 'USGS')
   END DO
   DO i = 1, n
      CALL use_stmtfn(REAL(i)*1.e-3, h(1, i))
      CALL use_intproc(REAL(i), h(2, i))
      CALL use_opt(REAL(i), h(3, i), 0.5)
      CALL use_char(REAL(i), h(4, i), 'USGS')
   END DO
   IF (ALL(r(1, :) == h(1, :))) THEN; PRINT '(a)', 'PROBE F-STMTFN PASS'; ELSE; PRINT '(a)', 'PROBE F-STMTFN FAIL'; END IF
   IF (ALL(r(2, :) == h(2, :))) THEN; PRINT '(a)', 'PROBE F-INTPROC PASS'; ELSE; PRINT '(a)', 'PROBE F-INTPROC FAIL'; END IF
   IF (ALL(r(3, :) == h(3, :))) THEN; PRINT '(a)', 'PROBE F-OPT PASS'; ELSE; PRINT '(a)', 'PROBE F-OPT FAIL'; END IF
   IF (ALL(r(4, :) == h(4, :))) THEN; PRINT '(a)', 'PROBE F-CHAR PASS'; ELSE; PRINT '(a)', 'PROBE F-CHAR FAIL'; END IF
END PROGRAM f_langfeat
