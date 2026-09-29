! C interface to module_repro_math for the host-side accuracy tests
! (port/tests/repro_math/test_accuracy.py, plan.md T-RM-ACC).
!
! Function ids: 1 exp, 2 log, 3 log10, 4 sin, 5 cos, 6 tan, 7 asin, 8 acos,
! 9 atan, 10 sinh, 11 cosh, 12 tanh, 13 atan2(y=a,x=b), 14 pow(a,b),
! 15 mod(a,b)

SUBROUTINE rm_eval_r4(fid, n, a, b, out) BIND(C, NAME='rm_eval_r4')
   USE ISO_C_BINDING
   USE module_repro_math
   IMPLICIT NONE
   INTEGER(C_INT), VALUE :: fid
   INTEGER(C_INT64_T), VALUE :: n
   REAL(C_FLOAT), INTENT(IN) :: a(n), b(n)
   REAL(C_FLOAT), INTENT(OUT) :: out(n)
   INTEGER(C_INT64_T) :: i

!$omp parallel do schedule(static)
   DO i = 1, n
      SELECT CASE (fid)
      CASE (1)
         out(i) = rp_exp(a(i))
      CASE (2)
         out(i) = rp_log(a(i))
      CASE (3)
         out(i) = rp_log10(a(i))
      CASE (4)
         out(i) = rp_sin(a(i))
      CASE (5)
         out(i) = rp_cos(a(i))
      CASE (6)
         out(i) = rp_tan(a(i))
      CASE (7)
         out(i) = rp_asin(a(i))
      CASE (8)
         out(i) = rp_acos(a(i))
      CASE (9)
         out(i) = rp_atan(a(i))
      CASE (10)
         out(i) = rp_sinh(a(i))
      CASE (11)
         out(i) = rp_cosh(a(i))
      CASE (12)
         out(i) = rp_tanh(a(i))
      CASE (13)
         out(i) = rp_atan2(a(i), b(i))
      CASE (14)
         out(i) = rp_pow(a(i), b(i))
      CASE (15)
         out(i) = rp_mod(a(i), b(i))
      END SELECT
   END DO
!$omp end parallel do
END SUBROUTINE rm_eval_r4

SUBROUTINE rm_eval_r8(fid, n, a, b, out) BIND(C, NAME='rm_eval_r8')
   USE ISO_C_BINDING
   USE module_repro_math
   IMPLICIT NONE
   INTEGER(C_INT), VALUE :: fid
   INTEGER(C_INT64_T), VALUE :: n
   REAL(C_DOUBLE), INTENT(IN) :: a(n), b(n)
   REAL(C_DOUBLE), INTENT(OUT) :: out(n)
   INTEGER(C_INT64_T) :: i

!$omp parallel do schedule(static)
   DO i = 1, n
      SELECT CASE (fid)
      CASE (1)
         out(i) = rp_exp(a(i))
      CASE (2)
         out(i) = rp_log(a(i))
      CASE (3)
         out(i) = rp_log10(a(i))
      CASE (4)
         out(i) = rp_sin(a(i))
      CASE (5)
         out(i) = rp_cos(a(i))
      CASE (6)
         out(i) = rp_tan(a(i))
      CASE (7)
         out(i) = rp_asin(a(i))
      CASE (8)
         out(i) = rp_acos(a(i))
      CASE (9)
         out(i) = rp_atan(a(i))
      CASE (10)
         out(i) = rp_sinh(a(i))
      CASE (11)
         out(i) = rp_cosh(a(i))
      CASE (12)
         out(i) = rp_tanh(a(i))
      CASE (13)
         out(i) = rp_atan2(a(i), b(i))
      CASE (14)
         out(i) = rp_pow(a(i), b(i))
      CASE (15)
         out(i) = rp_mod(a(i), b(i))
      END SELECT
   END DO
!$omp end parallel do
END SUBROUTINE rm_eval_r8

! Exhaustive REAL(4) sweep of a 1-argument function: bit patterns lo..hi
! (inclusive, as unsigned 32-bit integers), results written to out.
SUBROUTINE rm_sweep_r4(fid, lo, hi, out) BIND(C, NAME='rm_sweep_r4')
   USE ISO_C_BINDING
   USE module_repro_math
   IMPLICIT NONE
   INTEGER(C_INT), VALUE :: fid
   INTEGER(C_INT64_T), VALUE :: lo, hi
   REAL(C_FLOAT), INTENT(OUT) :: out(hi - lo + 1)
   INTEGER(C_INT64_T) :: k
   INTEGER(C_INT32_T) :: bits
   REAL(C_FLOAT) :: x

!$omp parallel do schedule(static) private(bits, x)
   DO k = lo, hi
      IF (k >= 2147483648_C_INT64_T) THEN
         bits = INT(k - 4294967296_C_INT64_T, C_INT32_T)
      ELSE
         bits = INT(k, C_INT32_T)
      END IF
      x = TRANSFER(bits, x)
      SELECT CASE (fid)
      CASE (1)
         out(k - lo + 1) = rp_exp(x)
      CASE (2)
         out(k - lo + 1) = rp_log(x)
      CASE (3)
         out(k - lo + 1) = rp_log10(x)
      CASE (4)
         out(k - lo + 1) = rp_sin(x)
      CASE (5)
         out(k - lo + 1) = rp_cos(x)
      CASE (6)
         out(k - lo + 1) = rp_tan(x)
      CASE (7)
         out(k - lo + 1) = rp_asin(x)
      CASE (8)
         out(k - lo + 1) = rp_acos(x)
      CASE (9)
         out(k - lo + 1) = rp_atan(x)
      CASE (10)
         out(k - lo + 1) = rp_sinh(x)
      CASE (11)
         out(k - lo + 1) = rp_cosh(x)
      CASE (12)
         out(k - lo + 1) = rp_tanh(x)
      END SELECT
   END DO
!$omp end parallel do
END SUBROUTINE rm_sweep_r4
