! Shared helpers for the host-vs-device tests in port/tests/repro_math
! (plan.md P0.5: T-FMA, T-SIGNZERO, T-MINMAX, T-SUBNORM, T-RM-EXH, T-RM-POW,
! T-RM-D).  Every test computes the same thing on the host and in an OpenMP
! target region and compares bit patterns.

MODULE rm_testlib
   USE omp_lib
   USE module_repro_math
   IMPLICIT NONE

   INTEGER, PARAMETER :: r4 = SELECTED_REAL_KIND(6,37)
   INTEGER, PARAMETER :: r8 = SELECTED_REAL_KIND(15,307)
   INTEGER, PARAMETER :: i4 = SELECTED_INT_KIND(9)
   INTEGER, PARAMETER :: i8 = SELECTED_INT_KIND(18)

   CHARACTER(LEN=6), PARAMETER :: fname(15) = (/ 'exp   ', 'log   ', 'log10 ', 'sin   ', &
      'cos   ', 'tan   ', 'asin  ', 'acos  ', 'atan  ', 'sinh  ', 'cosh  ', 'tanh  ',      &
      'atan2 ', 'pow   ', 'mod   ' /)

CONTAINS

   ! .TRUE. if target regions run on a GPU
   LOGICAL FUNCTION target_is_device()
      LOGICAL :: initial
      initial = .TRUE.
!$omp target map(from: initial)
      initial = omp_is_initial_device()
!$omp end target
      target_is_device = .NOT. initial
   END FUNCTION target_is_device

   ! Stop unless target regions run on a device (or ALLOW_HOST=1).
   SUBROUTINE require_device()
      CHARACTER(LEN=8) :: v
      INTEGER :: st
      IF (target_is_device()) THEN
         PRINT '(a,i0)', 'device: OpenMP default device ', omp_get_default_device()
         RETURN
      END IF
      CALL get_environment_variable('ALLOW_HOST', v, status=st)
      IF (st /= 0 .OR. TRIM(v) /= '1') THEN
         PRINT '(a)', 'ERROR: target regions run on the host, so this host-vs-device test is not valid.'
         PRINT '(a)', '       Set ALLOW_HOST=1 to run it anyway (compile check only).'
         STOP 3
      END IF
      PRINT '(a)', 'WARNING: target regions run on the host (ALLOW_HOST=1); results only check the program.'
   END SUBROUTINE require_device

   ! splitmix64 pseudo-random generator (host only)
   FUNCTION splitmix64(s) RESULT(z)
      INTEGER(i8), INTENT(INOUT) :: s
      INTEGER(i8) :: z
      s = s - 7046029254386353131_i8
      z = s
      z = IEOR(z, ISHFT(z, -30))*(-4658895280553007687_i8)
      z = IEOR(z, ISHFT(z, -27))*(-7723592293110705685_i8)
      z = IEOR(z, ISHFT(z, -31))
   END FUNCTION splitmix64

   ! REAL(4) with the given bit pattern (low 32 bits of b)
   PURE FUNCTION f4(b) RESULT(x)
!$omp declare target
      INTEGER(i8), INTENT(IN) :: b
      REAL(r4) :: x
      INTEGER(i4) :: ib
      INTEGER(i8) :: u
      u = IAND(b, 4294967295_i8)
      IF (u >= 2147483648_i8) THEN
         ib = INT(u - 4294967296_i8, i4)
      ELSE
         ib = INT(u, i4)
      END IF
      x = TRANSFER(ib, x)
   END FUNCTION f4

   PURE FUNCTION bits4(x) RESULT(ib)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      INTEGER(i4) :: ib
      ib = TRANSFER(x, ib)
   END FUNCTION bits4

   PURE FUNCTION bits8(x) RESULT(ib)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      INTEGER(i8) :: ib
      ib = TRANSFER(x, ib)
   END FUNCTION bits8

   ! rp_* function f applied to REAL(4) arguments, result bits
   PURE FUNCTION eval4(f, a, b) RESULT(ib)
!$omp declare target
      INTEGER, INTENT(IN) :: f
      REAL(r4), INTENT(IN) :: a, b
      INTEGER(i4) :: ib
      REAL(r4) :: y
      SELECT CASE (f)
      CASE (1)
         y = rp_exp(a)
      CASE (2)
         y = rp_log(a)
      CASE (3)
         y = rp_log10(a)
      CASE (4)
         y = rp_sin(a)
      CASE (5)
         y = rp_cos(a)
      CASE (6)
         y = rp_tan(a)
      CASE (7)
         y = rp_asin(a)
      CASE (8)
         y = rp_acos(a)
      CASE (9)
         y = rp_atan(a)
      CASE (10)
         y = rp_sinh(a)
      CASE (11)
         y = rp_cosh(a)
      CASE (12)
         y = rp_tanh(a)
      CASE (13)
         y = rp_atan2(a, b)
      CASE (14)
         y = rp_pow(a, b)
      CASE DEFAULT
         y = rp_mod(a, b)
      END SELECT
      ib = TRANSFER(y, ib)
   END FUNCTION eval4

   ! rp_* function f applied to REAL(8) arguments, result bits
   PURE FUNCTION eval8(f, a, b) RESULT(ib)
!$omp declare target
      INTEGER, INTENT(IN) :: f
      REAL(r8), INTENT(IN) :: a, b
      INTEGER(i8) :: ib
      REAL(r8) :: y
      SELECT CASE (f)
      CASE (1)
         y = rp_exp(a)
      CASE (2)
         y = rp_log(a)
      CASE (3)
         y = rp_log10(a)
      CASE (4)
         y = rp_sin(a)
      CASE (5)
         y = rp_cos(a)
      CASE (6)
         y = rp_tan(a)
      CASE (7)
         y = rp_asin(a)
      CASE (8)
         y = rp_acos(a)
      CASE (9)
         y = rp_atan(a)
      CASE (10)
         y = rp_sinh(a)
      CASE (11)
         y = rp_cosh(a)
      CASE (12)
         y = rp_tanh(a)
      CASE (13)
         y = rp_atan2(a, b)
      CASE (14)
         y = rp_pow(a, b)
      CASE DEFAULT
         y = rp_mod(a, b)
      END SELECT
      ib = TRANSFER(y, ib)
   END FUNCTION eval8

   SUBROUTINE report(test, nbad, ntot)
      CHARACTER(LEN=*), INTENT(IN) :: test
      INTEGER(i8), INTENT(IN) :: nbad, ntot
      IF (nbad == 0_i8) THEN
         PRINT '(a,a,a,i0,a)', 'PASS  ', test, '  (', ntot, ' values)'
      ELSE
         PRINT '(a,a,a,i0,a,i0,a)', 'FAIL  ', test, '  ', nbad, ' of ', ntot, ' differ'
      END IF
   END SUBROUTINE report

END MODULE rm_testlib
