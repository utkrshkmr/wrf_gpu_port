!WRF:DRIVER_LAYER:UTIL
!
! module_repro_math: reproducible elementary functions for the WRF GPU port
! (plan.md P0.5).
!
! Every rp_* function gives the same bits on the CPU and on the GPU because it
! is built only from IEEE basic operations (+ - * / and SQRT, all correctly
! rounded) and exact bit manipulation.  No vendor math library is called.
!
!   REAL(4) arguments: converted to REAL(8), evaluated with the double
!     algorithm below (error < 1 ulp of double), rounded once to REAL(4).
!     This is correctly rounded except in rare cases very close to a
!     rounding boundary (reported by the accuracy test).
!   REAL(8) arguments: the fdlibm 5.3 algorithms (error < 1 ulp).
!   NaN results are returned as one canonical quiet NaN (Z7FC00000 or
!     Z7FF8000000000000), because hardware NaN payloads differ between
!     CPU and GPU.
!
! Without -DREPRO_MATH every rp_* function returns the Fortran intrinsic, so
! such a build behaves like upstream WRF.
!
! Generic names and specifics:
!   rp_exp rp_log rp_log10 rp_sin rp_cos rp_tan rp_asin rp_acos rp_atan
!   rp_sinh rp_cosh rp_tanh                   : REAL(4), REAL(8)
!   rp_atan2(y,x)                             : (4,4) (8,8)
!   rp_pow(x,y) = x**y                        : (4,4) (8,8) (4,8) (8,4)
!                                               (4,i4) (8,i4) (i4,i4)
!                                               (i4,4) (i4,8)
!     Integer exponents are evaluated exactly as the original x**n.
!   rp_mod(a,p) = MOD(a,p)                    : (4,4) (8,8) (i4,i4) (i8,i8)
!     The REAL versions are exact (like C fmod), so they equal the
!     intrinsic bit for bit.
!
! Portions of this file are Fortran translations of fdlibm 5.3
! (e_exp.c, e_log.c, e_log10.c, e_pow.c, s_sin.c, s_cos.c, s_tan.c,
! k_sin.c, k_cos.c, k_tan.c, e_rem_pio2.c, k_rem_pio2.c, s_atan.c,
! e_atan2.c, e_asin.c, e_acos.c, s_expm1.c, e_sinh.c, e_cosh.c,
! s_tanh.c, s_scalbn.c), which carry this notice:
!
! ====================================================
! Copyright (C) 1993-2004 by Sun Microsystems, Inc. All rights reserved.
!
! Permission to use, copy, modify, and distribute this
! software is freely granted, provided that this notice
! is preserved.
! ====================================================
!
! Deviations from fdlibm: canonical NaN results; pow(+1,y) = 1 and
! pow(-1,+-inf) = 1 as in C99.
!
! Note for editors: the WRF build removes quotes from any line on which a
! comment character appears before a quote, so never put a comment on the
! same line before a hex literal.

MODULE module_repro_math

   IMPLICIT NONE
   PRIVATE

   INTEGER, PARAMETER :: r4 = SELECTED_REAL_KIND(6,37)
   INTEGER, PARAMETER :: r8 = SELECTED_REAL_KIND(15,307)
   INTEGER, PARAMETER :: i4 = SELECTED_INT_KIND(9)
   INTEGER, PARAMETER :: i8 = SELECTED_INT_KIND(18)

   PUBLIC :: rp_exp, rp_log, rp_log10, rp_pow, rp_sin, rp_cos, rp_tan
   PUBLIC :: rp_asin, rp_acos, rp_atan, rp_atan2, rp_sinh, rp_cosh, rp_tanh
   PUBLIC :: rp_mod, rp_repro_enabled

   INTERFACE rp_exp
      MODULE PROCEDURE rp_exp_r4, rp_exp_r8
   END INTERFACE
   INTERFACE rp_log
      MODULE PROCEDURE rp_log_r4, rp_log_r8
   END INTERFACE
   INTERFACE rp_log10
      MODULE PROCEDURE rp_log10_r4, rp_log10_r8
   END INTERFACE
   INTERFACE rp_sin
      MODULE PROCEDURE rp_sin_r4, rp_sin_r8
   END INTERFACE
   INTERFACE rp_cos
      MODULE PROCEDURE rp_cos_r4, rp_cos_r8
   END INTERFACE
   INTERFACE rp_tan
      MODULE PROCEDURE rp_tan_r4, rp_tan_r8
   END INTERFACE
   INTERFACE rp_asin
      MODULE PROCEDURE rp_asin_r4, rp_asin_r8
   END INTERFACE
   INTERFACE rp_acos
      MODULE PROCEDURE rp_acos_r4, rp_acos_r8
   END INTERFACE
   INTERFACE rp_atan
      MODULE PROCEDURE rp_atan_r4, rp_atan_r8
   END INTERFACE
   INTERFACE rp_atan2
      MODULE PROCEDURE rp_atan2_r4, rp_atan2_r8
   END INTERFACE
   INTERFACE rp_sinh
      MODULE PROCEDURE rp_sinh_r4, rp_sinh_r8
   END INTERFACE
   INTERFACE rp_cosh
      MODULE PROCEDURE rp_cosh_r4, rp_cosh_r8
   END INTERFACE
   INTERFACE rp_tanh
      MODULE PROCEDURE rp_tanh_r4, rp_tanh_r8
   END INTERFACE
   INTERFACE rp_pow
      MODULE PROCEDURE rp_pow_r4, rp_pow_r8, rp_pow_r4r8, rp_pow_r8r4,  &
                       rp_pow_r4i4, rp_pow_r8i4, rp_pow_i4i4,           &
                       rp_pow_i4r4, rp_pow_i4r8
   END INTERFACE
   INTERFACE rp_mod
      MODULE PROCEDURE rp_mod_r4, rp_mod_r8, rp_mod_i4, rp_mod_i8
   END INTERFACE

   ! Bit patterns
   INTEGER(i8), PARAMETER :: MASK32   = INT(Z'00000000FFFFFFFF', i8)
   INTEGER(i8), PARAMETER :: M31      = INT(Z'7FFFFFFF', i8)
   INTEGER(i8), PARAMETER :: HI_INF   = INT(Z'7FF00000', i8)
   INTEGER(i8), PARAMETER :: INF_BITS = INT(Z'7FF0000000000000', i8)
   INTEGER(i8), PARAMETER :: NAN_BITS = INT(Z'7FF8000000000000', i8)
   INTEGER(i8), PARAMETER :: ABS_MASK = INT(Z'7FFFFFFFFFFFFFFF', i8)
   INTEGER(i8), PARAMETER :: MANT52   = INT(Z'000FFFFFFFFFFFFF', i8)
   INTEGER(i8), PARAMETER :: HIDDEN52 = INT(Z'0010000000000000', i8)
   INTEGER(i4), PARAMETER :: NAN4_BITS = INT(Z'7FC00000', i4)

   ! 2/pi in 24-bit chunks (fdlibm e_rem_pio2.c)
   INTEGER(i8), PARAMETER :: two_over_pi(0:65) = (/                                    &
      INT(Z'A2F983',i8), INT(Z'6E4E44',i8), INT(Z'1529FC',i8), INT(Z'2757D1',i8),     &
      INT(Z'F534DD',i8), INT(Z'C0DB62',i8), INT(Z'95993C',i8), INT(Z'439041',i8),     &
      INT(Z'FE5163',i8), INT(Z'ABDEBB',i8), INT(Z'C561B7',i8), INT(Z'246E3A',i8),     &
      INT(Z'424DD2',i8), INT(Z'E00649',i8), INT(Z'2EEA09',i8), INT(Z'D1921C',i8),     &
      INT(Z'FE1DEB',i8), INT(Z'1CB129',i8), INT(Z'A73EE8',i8), INT(Z'8235F5',i8),     &
      INT(Z'2EBB44',i8), INT(Z'84E99C',i8), INT(Z'7026B4',i8), INT(Z'5F7E41',i8),     &
      INT(Z'3991D6',i8), INT(Z'398353',i8), INT(Z'39F49C',i8), INT(Z'845F8B',i8),     &
      INT(Z'BDF928',i8), INT(Z'3B1FF8',i8), INT(Z'97FFDE',i8), INT(Z'05980F',i8),     &
      INT(Z'EF2F11',i8), INT(Z'8B5A0A',i8), INT(Z'6D1F6D',i8), INT(Z'367ECF',i8),     &
      INT(Z'27CB09',i8), INT(Z'B74F46',i8), INT(Z'3F669E',i8), INT(Z'5FEA2D',i8),     &
      INT(Z'7527BA',i8), INT(Z'C7EBE5',i8), INT(Z'F17B3D',i8), INT(Z'0739F7',i8),     &
      INT(Z'8A5292',i8), INT(Z'EA6BFB',i8), INT(Z'5FB11F',i8), INT(Z'8D5D08',i8),     &
      INT(Z'560330',i8), INT(Z'46FC7B',i8), INT(Z'6BABF0',i8), INT(Z'CFBC20',i8),     &
      INT(Z'9AF436',i8), INT(Z'1DA9E3',i8), INT(Z'91615E',i8), INT(Z'E61B08',i8),     &
      INT(Z'659985',i8), INT(Z'5F14A0',i8), INT(Z'68408D',i8), INT(Z'FFD880',i8),     &
      INT(Z'4D7327',i8), INT(Z'310606',i8), INT(Z'1556CA',i8), INT(Z'73A8C9',i8),     &
      INT(Z'60E27B',i8), INT(Z'C08C6B',i8) /)

   ! High words of n*pi/2, n = 1..32 (fdlibm e_rem_pio2.c)
   INTEGER(i8), PARAMETER :: npio2_hw(1:32) = (/                                                      &
      INT(Z'3FF921FB',i8), INT(Z'400921FB',i8), INT(Z'4012D97C',i8), INT(Z'401921FB',i8),           &
      INT(Z'401F6A7A',i8), INT(Z'4022D97C',i8), INT(Z'4025FDBB',i8), INT(Z'402921FB',i8),           &
      INT(Z'402C463A',i8), INT(Z'402F6A7A',i8), INT(Z'4031475C',i8), INT(Z'4032D97C',i8),           &
      INT(Z'40346B9C',i8), INT(Z'4035FDBB',i8), INT(Z'40378FDB',i8), INT(Z'403921FB',i8),           &
      INT(Z'403AB41B',i8), INT(Z'403C463A',i8), INT(Z'403DD85A',i8), INT(Z'403F6A7A',i8),           &
      INT(Z'40407E4C',i8), INT(Z'4041475C',i8), INT(Z'4042106C',i8), INT(Z'4042D97C',i8),           &
      INT(Z'4043A28C',i8), INT(Z'40446B9C',i8), INT(Z'404534AC',i8), INT(Z'4045FDBB',i8),           &
      INT(Z'4046C6CB',i8), INT(Z'40478FDB',i8), INT(Z'404858EB',i8), INT(Z'404921FB',i8) /)

   ! pi/2 in 24-bit pieces (fdlibm k_rem_pio2.c)
   REAL(r8), PARAMETER :: PIo2(0:7) = (/                    &
      1.57079625129699707031e+00_r8, 7.54978941586159635335e-08_r8, &
      5.39030252995776476554e-15_r8, 3.28200341580791294123e-22_r8, &
      1.27065575308067607349e-29_r8, 1.22933308981111328932e-36_r8, &
      2.73370053816464559624e-44_r8, 2.16741683877804819444e-51_r8 /)

   ! atan tables (fdlibm s_atan.c)
   REAL(r8), PARAMETER :: atanhi(0:3) = (/                  &
      4.63647609000806093515e-01_r8, 7.85398163397448278999e-01_r8, &
      9.82793723247329054082e-01_r8, 1.57079632679489655800e+00_r8 /)
   REAL(r8), PARAMETER :: atanlo(0:3) = (/                  &
      2.26987774529616870924e-17_r8, 3.06161699786838301793e-17_r8, &
      1.39033110312309984516e-17_r8, 6.12323399573676603587e-17_r8 /)
   REAL(r8), PARAMETER :: aT(0:10) = (/                     &
      3.33333333333329318027e-01_r8, -1.99999999998764832476e-01_r8, &
      1.42857142725034663711e-01_r8, -1.11111104054623557880e-01_r8, &
      9.09088713343650656196e-02_r8, -7.69187620504482999495e-02_r8, &
      6.66107313738753120669e-02_r8, -5.83357013379057348645e-02_r8, &
      4.97687799461593236017e-02_r8, -3.65315727442169155270e-02_r8, &
      1.62858201153657823623e-02_r8 /)

   ! tan kernel coefficients (fdlibm k_tan.c)
   REAL(r8), PARAMETER :: TT(0:12) = (/                     &
      3.33333333333334091986e-01_r8, 1.33333333333201242699e-01_r8, &
      5.39682539762260521377e-02_r8, 2.18694882948595424599e-02_r8, &
      8.86323982359930005737e-03_r8, 3.59207910759131235356e-03_r8, &
      1.45620945432529025516e-03_r8, 5.88041240820264096874e-04_r8, &
      2.46463134818469906812e-04_r8, 7.81794442939557092300e-05_r8, &
      7.14072491382608190305e-05_r8, -1.85586374855275456654e-05_r8, &
      2.59073051863633712884e-05_r8 /)

CONTAINS

!-----------------------------------------------------------------------
! Status
!-----------------------------------------------------------------------

   LOGICAL FUNCTION rp_repro_enabled()
#ifdef REPRO_MATH
      rp_repro_enabled = .TRUE.
#else
      rp_repro_enabled = .FALSE.
#endif
   END FUNCTION rp_repro_enabled

!-----------------------------------------------------------------------
! Bit helpers
!-----------------------------------------------------------------------

   ! unsigned high 32-bit word of x, in 0 .. 2**32-1
   PURE FUNCTION hiw(x) RESULT(h)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      INTEGER(i8) :: h
      h = ISHFT(TRANSFER(x, 0_i8), -32)
   END FUNCTION hiw

   ! unsigned low 32-bit word of x
   PURE FUNCTION low(x) RESULT(l)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      INTEGER(i8) :: l
      l = IAND(TRANSFER(x, 0_i8), MASK32)
   END FUNCTION low

   ! double from high and low words
   PURE FUNCTION mkd(h, l) RESULT(x)
!$omp declare target
      INTEGER(i8), INTENT(IN) :: h, l
      REAL(r8) :: x
      x = TRANSFER(IOR(ISHFT(IAND(h, MASK32), 32), IAND(l, MASK32)), 1.0_r8)
   END FUNCTION mkd

   ! x with its high word replaced (fdlibm __HI(x) = h)
   PURE FUNCTION set_hi(x, h) RESULT(y)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      INTEGER(i8), INTENT(IN) :: h
      REAL(r8) :: y
      y = mkd(h, low(x))
   END FUNCTION set_hi

   ! x with its low word cleared (fdlibm __LO(x) = 0)
   PURE FUNCTION lo0(x) RESULT(y)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: y
      y = TRANSFER(IAND(TRANSFER(x, 0_i8), NOT(MASK32)), 1.0_r8)
   END FUNCTION lo0

   PURE FUNCTION fabs8(x) RESULT(y)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: y
      y = TRANSFER(IAND(TRANSFER(x, 0_i8), ABS_MASK), 1.0_r8)
   END FUNCTION fabs8

   ! |a| with the sign bit of b
   PURE FUNCTION copysign8(a, b) RESULT(y)
!$omp declare target
      REAL(r8), INTENT(IN) :: a, b
      REAL(r8) :: y
      y = TRANSFER(IOR(IAND(TRANSFER(a, 0_i8), ABS_MASK), IAND(TRANSFER(b, 0_i8), NOT(ABS_MASK))), 1.0_r8)
   END FUNCTION copysign8

   PURE FUNCTION inf8() RESULT(y)
!$omp declare target
      REAL(r8) :: y
      y = TRANSFER(INF_BITS, 1.0_r8)
   END FUNCTION inf8

   PURE FUNCTION nan8() RESULT(y)
!$omp declare target
      REAL(r8) :: y
      y = TRANSFER(NAN_BITS, 1.0_r8)
   END FUNCTION nan8

   ! arithmetic shift right (floor division by 2**s), as C >> on signed int
   PURE FUNCTION asr(v, s) RESULT(r)
!$omp declare target
      INTEGER(i8), INTENT(IN) :: v
      INTEGER, INTENT(IN) :: s
      INTEGER(i8) :: r
      IF (v >= 0_i8) THEN
         r = ISHFT(v, -s)
      ELSE
         r = NOT(ISHFT(NOT(v), -s))
      END IF
   END FUNCTION asr

   ! REAL(8) result -> REAL(4), canonical NaN
   PURE FUNCTION to_r4(d) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: d
      REAL(r4) :: r
      IF (d /= d) THEN
         r = TRANSFER(NAN4_BITS, 1.0_r4)
      ELSE
         r = REAL(d, r4)
      END IF
   END FUNCTION to_r4

   ! canonical NaN for REAL(8) results
   PURE FUNCTION canon8(d) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: d
      REAL(r8) :: r
      IF (d /= d) THEN
         r = nan8()
      ELSE
         r = d
      END IF
   END FUNCTION canon8

!-----------------------------------------------------------------------
! scalbn (s_scalbn.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_scalbn(xin, n) RESULT(x)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin
      INTEGER(i8), INTENT(IN) :: n
      REAL(r8) :: x
      REAL(r8), PARAMETER :: two54  = 1.80143985094819840000e+16_r8
      REAL(r8), PARAMETER :: twom54 = 5.55111512312578270212e-17_r8
      INTEGER(i8) :: hx, lx, k

      x  = xin
      hx = hiw(x)
      lx = low(x)
      k  = ISHFT(IAND(hx, HI_INF), -20)
      IF (k == 0_i8) THEN
         IF (IOR(lx, IAND(hx, M31)) == 0_i8) RETURN
         x  = x*two54
         hx = hiw(x)
         k  = ISHFT(IAND(hx, HI_INF), -20) - 54_i8
         IF (n < -50000_i8) THEN
            x = copysign8(0.0_r8, x)
            RETURN
         END IF
      END IF
      IF (k == 2047_i8) THEN
         x = canon8(x + x)
         RETURN
      END IF
      k = k + n
      IF (k > 2046_i8) THEN
         x = copysign8(inf8(), x)
         RETURN
      END IF
      IF (k > 0_i8) THEN
         x = set_hi(x, IOR(IAND(hx, INT(Z'800FFFFF', i8)), ISHFT(k, 20)))
         RETURN
      END IF
      IF (k <= -54_i8) THEN
         IF (n > 50000_i8) THEN
            x = copysign8(inf8(), x)
         ELSE
            x = copysign8(0.0_r8, x)
         END IF
         RETURN
      END IF
      k = k + 54_i8
      x = set_hi(x, IOR(IAND(hx, INT(Z'800FFFFF', i8)), ISHFT(k, 20)))
      x = x*twom54
   END FUNCTION rm_scalbn

!-----------------------------------------------------------------------
! exp (e_exp.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_exp(xin) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin
      REAL(r8) :: res
      REAL(r8), PARAMETER :: o_threshold =  7.09782712893383973096e+02_r8
      REAL(r8), PARAMETER :: u_threshold = -7.45133219101941108420e+02_r8
      REAL(r8), PARAMETER :: ln2hi  = 6.93147180369123816490e-01_r8
      REAL(r8), PARAMETER :: ln2lo  = 1.90821492927058770002e-10_r8
      REAL(r8), PARAMETER :: invln2 = 1.44269504088896338700e+00_r8
      REAL(r8), PARAMETER :: twom1000 = 9.33263618503218878990e-302_r8
      REAL(r8), PARAMETER :: P1 =  1.66666666666666019037e-01_r8
      REAL(r8), PARAMETER :: P2 = -2.77777777770155933842e-03_r8
      REAL(r8), PARAMETER :: P3 =  6.61375632143793436117e-05_r8
      REAL(r8), PARAMETER :: P4 = -1.65339022054652515390e-06_r8
      REAL(r8), PARAMETER :: P5 =  4.13813679705723846039e-08_r8
      REAL(r8) :: x, y, hi, lo, c, t
      INTEGER(i8) :: hx, k, xsb

      x   = xin
      hx  = hiw(x)
      xsb = ISHFT(hx, -31)
      hx  = IAND(hx, M31)
      hi  = 0.0_r8
      lo  = 0.0_r8
      k   = 0_i8

      IF (hx >= INT(Z'40862E42', i8)) THEN
         IF (hx >= HI_INF) THEN
            IF (IOR(IAND(hx, INT(Z'000FFFFF', i8)), low(x)) /= 0_i8) THEN
               res = nan8()
            ELSE IF (xsb == 0_i8) THEN
               res = x
            ELSE
               res = 0.0_r8
            END IF
            RETURN
         END IF
         IF (x > o_threshold) THEN
            res = inf8()
            RETURN
         END IF
         IF (x < u_threshold) THEN
            res = 0.0_r8
            RETURN
         END IF
      END IF

      IF (hx > INT(Z'3FD62E42', i8)) THEN
         IF (hx < INT(Z'3FF0A2B2', i8)) THEN
            IF (xsb == 0_i8) THEN
               hi = x - ln2hi
               lo = ln2lo
               k  = 1_i8
            ELSE
               hi = x + ln2hi
               lo = -ln2lo
               k  = -1_i8
            END IF
         ELSE
            IF (xsb == 0_i8) THEN
               k = INT(invln2*x + 0.5_r8, i8)
            ELSE
               k = INT(invln2*x - 0.5_r8, i8)
            END IF
            t  = REAL(k, r8)
            hi = x - t*ln2hi
            lo = t*ln2lo
         END IF
         x = hi - lo
      ELSE IF (hx < INT(Z'3E300000', i8)) THEN
         res = 1.0_r8 + x
         RETURN
      ELSE
         k = 0_i8
      END IF

      t = x*x
      c = x - t*(P1 + t*(P2 + t*(P3 + t*(P4 + t*P5))))
      IF (k == 0_i8) THEN
         res = 1.0_r8 - ((x*c)/(c - 2.0_r8) - x)
         RETURN
      END IF
      y = 1.0_r8 - ((lo - (x*c)/(2.0_r8 - c)) - hi)
      IF (k >= -1021_i8) THEN
         res = set_hi(y, hiw(y) + k*1048576_i8)
      ELSE
         res = set_hi(y, hiw(y) + (k + 1000_i8)*1048576_i8)
         res = res*twom1000
      END IF
   END FUNCTION rm_exp

!-----------------------------------------------------------------------
! log (e_log.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_log(xin) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin
      REAL(r8) :: res
      REAL(r8), PARAMETER :: ln2_hi = 6.93147180369123816490e-01_r8
      REAL(r8), PARAMETER :: ln2_lo = 1.90821492927058770002e-10_r8
      REAL(r8), PARAMETER :: two54  = 1.80143985094819840000e+16_r8
      REAL(r8), PARAMETER :: Lg1 = 6.666666666666735130e-01_r8
      REAL(r8), PARAMETER :: Lg2 = 3.999999999940941908e-01_r8
      REAL(r8), PARAMETER :: Lg3 = 2.857142874366239149e-01_r8
      REAL(r8), PARAMETER :: Lg4 = 2.222219843214978396e-01_r8
      REAL(r8), PARAMETER :: Lg5 = 1.818357216161805012e-01_r8
      REAL(r8), PARAMETER :: Lg6 = 1.531383769920937332e-01_r8
      REAL(r8), PARAMETER :: Lg7 = 1.479819860511658591e-01_r8
      REAL(r8) :: x, hfsq, f, s, z, R, w, t1, t2, dk
      INTEGER(i8) :: k, hx, lx, i, j

      x  = xin
      hx = hiw(x)
      lx = low(x)
      k  = 0_i8
      IF (BTEST(hx, 31) .OR. hx < INT(Z'00100000', i8)) THEN
         IF (IOR(IAND(hx, M31), lx) == 0_i8) THEN
            res = -inf8()
            RETURN
         END IF
         IF (BTEST(hx, 31)) THEN
            res = nan8()
            RETURN
         END IF
         k  = k - 54_i8
         x  = x*two54
         hx = hiw(x)
      END IF
      IF (hx >= HI_INF) THEN
         res = canon8(x + x)
         RETURN
      END IF
      k  = k + ISHFT(hx, -20) - 1023_i8
      hx = IAND(hx, INT(Z'000FFFFF', i8))
      i  = IAND(hx + INT(Z'95F64', i8), INT(Z'100000', i8))
      x  = set_hi(x, IOR(hx, IEOR(i, INT(Z'3FF00000', i8))))
      k  = k + ISHFT(i, -20)
      f  = x - 1.0_r8
      IF (IAND(INT(Z'000FFFFF', i8), 2_i8 + hx) < 3_i8) THEN
         IF (f == 0.0_r8) THEN
            IF (k == 0_i8) THEN
               res = 0.0_r8
            ELSE
               dk  = REAL(k, r8)
               res = dk*ln2_hi + dk*ln2_lo
            END IF
            RETURN
         END IF
         R = (f*f)*(0.5_r8 - 0.33333333333333333_r8*f)
         IF (k == 0_i8) THEN
            res = f - R
         ELSE
            dk  = REAL(k, r8)
            res = dk*ln2_hi - ((R - dk*ln2_lo) - f)
         END IF
         RETURN
      END IF
      s  = f/(2.0_r8 + f)
      dk = REAL(k, r8)
      z  = s*s
      i  = hx - INT(Z'6147A', i8)
      w  = z*z
      j  = INT(Z'6B851', i8) - hx
      t1 = w*(Lg2 + w*(Lg4 + w*Lg6))
      t2 = z*(Lg1 + w*(Lg3 + w*(Lg5 + w*Lg7)))
      i  = IOR(i, j)
      R  = t2 + t1
      IF (i > 0_i8) THEN
         hfsq = (0.5_r8*f)*f
         IF (k == 0_i8) THEN
            res = f - (hfsq - s*(hfsq + R))
         ELSE
            res = dk*ln2_hi - ((hfsq - (s*(hfsq + R) + dk*ln2_lo)) - f)
         END IF
      ELSE
         IF (k == 0_i8) THEN
            res = f - s*(f - R)
         ELSE
            res = dk*ln2_hi - ((s*(f - R) - dk*ln2_lo) - f)
         END IF
      END IF
   END FUNCTION rm_log

!-----------------------------------------------------------------------
! log10 (e_log10.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_log10(xin) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin
      REAL(r8) :: res
      REAL(r8), PARAMETER :: two54     = 1.80143985094819840000e+16_r8
      REAL(r8), PARAMETER :: ivln10    = 4.34294481903251816668e-01_r8
      REAL(r8), PARAMETER :: log10_2hi = 3.01029995663611771306e-01_r8
      REAL(r8), PARAMETER :: log10_2lo = 3.69423907715893078616e-13_r8
      REAL(r8) :: x, y, z
      INTEGER(i8) :: i, k, hx, lx

      x  = xin
      hx = hiw(x)
      lx = low(x)
      k  = 0_i8
      IF (BTEST(hx, 31) .OR. hx < INT(Z'00100000', i8)) THEN
         IF (IOR(IAND(hx, M31), lx) == 0_i8) THEN
            res = -inf8()
            RETURN
         END IF
         IF (BTEST(hx, 31)) THEN
            res = nan8()
            RETURN
         END IF
         k  = k - 54_i8
         x  = x*two54
         hx = hiw(x)
      END IF
      IF (hx >= HI_INF) THEN
         res = canon8(x + x)
         RETURN
      END IF
      k = k + ISHFT(hx, -20) - 1023_i8
      IF (k < 0_i8) THEN
         i = 1_i8
      ELSE
         i = 0_i8
      END IF
      hx  = IOR(IAND(hx, INT(Z'000FFFFF', i8)), ISHFT(1023_i8 - i, 20))
      y   = REAL(k + i, r8)
      x   = set_hi(x, hx)
      z   = y*log10_2lo + ivln10*rm_log(x)
      res = z + y*log10_2hi
   END FUNCTION rm_log10

!-----------------------------------------------------------------------
! pow (e_pow.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_pow(x, y) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x, y
      REAL(r8) :: res
      REAL(r8), PARAMETER :: bp(0:1)   = (/ 1.0_r8, 1.5_r8 /)
      REAL(r8), PARAMETER :: dp_h(0:1) = (/ 0.0_r8, 5.84962487220764160156e-01_r8 /)
      REAL(r8), PARAMETER :: dp_l(0:1) = (/ 0.0_r8, 1.35003920212974897128e-08_r8 /)
      REAL(r8), PARAMETER :: two53 = 9007199254740992.0_r8
      REAL(r8), PARAMETER :: L1 = 5.99999999999994648725e-01_r8
      REAL(r8), PARAMETER :: L2 = 4.28571428578550184252e-01_r8
      REAL(r8), PARAMETER :: L3 = 3.33333329818377432918e-01_r8
      REAL(r8), PARAMETER :: L4 = 2.72728123808534006489e-01_r8
      REAL(r8), PARAMETER :: L5 = 2.30660745775561754067e-01_r8
      REAL(r8), PARAMETER :: L6 = 2.06975017800338417784e-01_r8
      REAL(r8), PARAMETER :: P1 =  1.66666666666666019037e-01_r8
      REAL(r8), PARAMETER :: P2 = -2.77777777770155933842e-03_r8
      REAL(r8), PARAMETER :: P3 =  6.61375632143793436117e-05_r8
      REAL(r8), PARAMETER :: P4 = -1.65339022054652515390e-06_r8
      REAL(r8), PARAMETER :: P5 =  4.13813679705723846039e-08_r8
      REAL(r8), PARAMETER :: lg2   =  6.93147180559945286227e-01_r8
      REAL(r8), PARAMETER :: lg2_h =  6.93147182464599609375e-01_r8
      REAL(r8), PARAMETER :: lg2_l = -1.90465429995776804525e-09_r8
      REAL(r8), PARAMETER :: ovt   =  8.0085662595372944372e-17_r8
      REAL(r8), PARAMETER :: cp    =  9.61796693925975554329e-01_r8
      REAL(r8), PARAMETER :: cp_h  =  9.61796700954437255859e-01_r8
      REAL(r8), PARAMETER :: cp_l  = -7.02846165095275826516e-09_r8
      REAL(r8), PARAMETER :: ivln2   = 1.44269504088896338700e+00_r8
      REAL(r8), PARAMETER :: ivln2_h = 1.44269502162933349609e+00_r8
      REAL(r8), PARAMETER :: ivln2_l = 1.92596299112661746887e-08_r8
      REAL(r8) :: z, ax, z_h, z_l, p_h, p_l, y1, t1, t2, rr, s, t, u, v, w
      REAL(r8) :: ss, s2, s_h, s_l, t_h, t_l
      INTEGER(i8) :: i, j, k, yisint, n, hx, hy, ix, iy, lx, ly, jj
      LOGICAL :: xneg, yneg

      hx = hiw(x)
      lx = low(x)
      hy = hiw(y)
      ly = low(y)
      ix = IAND(hx, M31)
      iy = IAND(hy, M31)
      xneg = BTEST(hx, 31)
      yneg = BTEST(hy, 31)

      ! x**0 = 1
      IF (IOR(iy, ly) == 0_i8) THEN
         res = 1.0_r8
         RETURN
      END IF
      ! 1**y = 1 (C99)
      IF (hx == INT(Z'3FF00000', i8) .AND. lx == 0_i8) THEN
         res = 1.0_r8
         RETURN
      END IF
      ! NaN
      IF (ix > HI_INF .OR. (ix == HI_INF .AND. lx /= 0_i8) .OR.   &
          iy > HI_INF .OR. (iy == HI_INF .AND. ly /= 0_i8)) THEN
         res = nan8()
         RETURN
      END IF

      ! yisint = 0: y not an integer; 1: odd integer; 2: even integer
      yisint = 0_i8
      IF (xneg) THEN
         IF (iy >= INT(Z'43400000', i8)) THEN
            yisint = 2_i8
         ELSE IF (iy >= INT(Z'3FF00000', i8)) THEN
            k = ISHFT(iy, -20) - 1023_i8
            IF (k > 20_i8) THEN
               j = ISHFT(ly, -INT(52_i8 - k))
               IF (ISHFT(j, INT(52_i8 - k)) == ly) yisint = 2_i8 - IAND(j, 1_i8)
            ELSE IF (ly == 0_i8) THEN
               j = ISHFT(iy, -INT(20_i8 - k))
               IF (ISHFT(j, INT(20_i8 - k)) == iy) yisint = 2_i8 - IAND(j, 1_i8)
            END IF
         END IF
      END IF

      ! special values of y
      IF (ly == 0_i8) THEN
         IF (iy == HI_INF) THEN
            IF (IOR(ix - INT(Z'3FF00000', i8), lx) == 0_i8) THEN
               res = 1.0_r8
            ELSE IF (ix >= INT(Z'3FF00000', i8)) THEN
               IF (.NOT. yneg) THEN
                  res = y
               ELSE
                  res = 0.0_r8
               END IF
            ELSE
               IF (yneg) THEN
                  res = -y
               ELSE
                  res = 0.0_r8
               END IF
            END IF
            RETURN
         END IF
         IF (iy == INT(Z'3FF00000', i8)) THEN
            IF (yneg) THEN
               res = 1.0_r8/x
            ELSE
               res = x
            END IF
            RETURN
         END IF
         IF (hy == INT(Z'40000000', i8)) THEN
            res = x*x
            RETURN
         END IF
         IF (hy == INT(Z'3FE00000', i8)) THEN
            IF (.NOT. xneg) THEN
               res = SQRT(x)
               RETURN
            END IF
         END IF
      END IF

      ax = fabs8(x)
      ! special values of x: +-0, +-inf, +-1
      IF (lx == 0_i8) THEN
         IF (ix == HI_INF .OR. ix == 0_i8 .OR. ix == INT(Z'3FF00000', i8)) THEN
            z = ax
            IF (yneg) z = 1.0_r8/z
            IF (xneg) THEN
               IF (IOR(ix - INT(Z'3FF00000', i8), yisint) == 0_i8) THEN
                  z = nan8()
               ELSE IF (yisint == 1_i8) THEN
                  z = -z
               END IF
            END IF
            res = z
            RETURN
         END IF
      END IF

      IF (xneg) THEN
         n = 0_i8
      ELSE
         n = 1_i8
      END IF
      ! (x<0)**(non-int) is NaN
      IF (IOR(n, yisint) == 0_i8) THEN
         res = nan8()
         RETURN
      END IF
      s = 1.0_r8
      IF (IOR(n, yisint - 1_i8) == 0_i8) s = -1.0_r8

      IF (iy > INT(Z'41E00000', i8)) THEN
         ! |y| > 2**31
         IF (iy > INT(Z'43F00000', i8)) THEN
            ! |y| > 2**64: must overflow or underflow
            IF (ix <= INT(Z'3FEFFFFF', i8)) THEN
               IF (yneg) THEN
                  res = inf8()
               ELSE
                  res = 0.0_r8
               END IF
               RETURN
            END IF
            IF (ix >= INT(Z'3FF00000', i8)) THEN
               IF (.NOT. yneg) THEN
                  res = inf8()
               ELSE
                  res = 0.0_r8
               END IF
               RETURN
            END IF
         END IF
         IF (ix < INT(Z'3FEFFFFF', i8)) THEN
            IF (yneg) THEN
               res = copysign8(inf8(), s)
            ELSE
               res = copysign8(0.0_r8, s)
            END IF
            RETURN
         END IF
         IF (ix > INT(Z'3FF00000', i8)) THEN
            IF (.NOT. yneg) THEN
               res = copysign8(inf8(), s)
            ELSE
               res = copysign8(0.0_r8, s)
            END IF
            RETURN
         END IF
         ! |1-x| <= 2**-20: log(x) by x-x^2/2+x^3/3-x^4/4
         t  = ax - 1.0_r8
         w  = (t*t)*(0.5_r8 - t*(0.3333333333333333333333_r8 - t*0.25_r8))
         u  = ivln2_h*t
         v  = t*ivln2_l - w*ivln2
         t1 = lo0(u + v)
         t2 = v - (t1 - u)
      ELSE
         n = 0_i8
         ! subnormal x
         IF (ix < INT(Z'00100000', i8)) THEN
            ax = ax*two53
            n  = n - 53_i8
            ix = hiw(ax)
         END IF
         n  = n + ISHFT(ix, -20) - 1023_i8
         j  = IAND(ix, INT(Z'000FFFFF', i8))
         ix = IOR(j, INT(Z'3FF00000', i8))
         IF (j <= INT(Z'3988E', i8)) THEN
            k = 0_i8
         ELSE IF (j < INT(Z'BB67A', i8)) THEN
            k = 1_i8
         ELSE
            k  = 0_i8
            n  = n + 1_i8
            ix = ix - INT(Z'00100000', i8)
         END IF
         ax = set_hi(ax, ix)

         ! ss = s_h+s_l = (x-1)/(x+1) or (x-1.5)/(x+1.5)
         u   = ax - bp(k)
         v   = 1.0_r8/(ax + bp(k))
         ss  = u*v
         s_h = lo0(ss)
         t_h = mkd(IOR(ISHFT(ix, -1), INT(Z'20000000', i8)) + INT(Z'00080000', i8) + ISHFT(k, 18), 0_i8)
         t_l = ax - (t_h - bp(k))
         s_l = v*((u - s_h*t_h) - s_h*t_l)
         ! log(ax)
         s2  = ss*ss
         rr  = (s2*s2)*(L1 + s2*(L2 + s2*(L3 + s2*(L4 + s2*(L5 + s2*L6)))))
         rr  = rr + s_l*(s_h + ss)
         s2  = s_h*s_h
         t_h = lo0((3.0_r8 + s2) + rr)
         t_l = rr - ((t_h - 3.0_r8) - s2)
         u   = s_h*t_h
         v   = s_l*t_h + t_l*ss
         p_h = lo0(u + v)
         p_l = v - (p_h - u)
         z_h = cp_h*p_h
         z_l = (cp_l*p_h + p_l*cp) + dp_l(k)
         t   = REAL(n, r8)
         t1  = lo0(((z_h + z_l) + dp_h(k)) + t)
         t2  = z_l - (((t1 - t) - dp_h(k)) - z_h)
      END IF

      ! (y1+y2)*(t1+t2)
      y1  = lo0(y)
      p_l = (y - y1)*t1 + y*t2
      p_h = y1*t1
      z   = p_l + p_h
      j   = hiw(z)
      i   = low(z)
      IF ((.NOT. BTEST(j, 31)) .AND. j >= INT(Z'40900000', i8)) THEN
         ! z >= 1024
         IF (IOR(j - INT(Z'40900000', i8), i) /= 0_i8) THEN
            res = copysign8(inf8(), s)
            RETURN
         ELSE IF (p_l + ovt > z - p_h) THEN
            res = copysign8(inf8(), s)
            RETURN
         END IF
      ELSE IF (IAND(j, M31) >= INT(Z'4090CC00', i8)) THEN
         ! z <= -1075
         IF (IOR(j - INT(Z'C090CC00', i8), i) /= 0_i8) THEN
            res = copysign8(0.0_r8, s)
            RETURN
         ELSE IF (p_l <= z - p_h) THEN
            res = copysign8(0.0_r8, s)
            RETURN
         END IF
      END IF

      ! 2**(p_h+p_l)
      i = IAND(j, M31)
      k = ISHFT(i, -20) - 1023_i8
      n = 0_i8
      IF (i > INT(Z'3FE00000', i8)) THEN
         n = IAND(j + ISHFT(INT(Z'00100000', i8), -INT(k + 1_i8)), MASK32)
         k = ISHFT(IAND(n, M31), -20) - 1023_i8
         t = mkd(IAND(n, IAND(NOT(ISHFT(INT(Z'000FFFFF', i8), -INT(k))), MASK32)), 0_i8)
         n = ISHFT(IOR(IAND(n, INT(Z'000FFFFF', i8)), INT(Z'00100000', i8)), -INT(20_i8 - k))
         IF (BTEST(j, 31)) n = -n
         p_h = p_h - t
      END IF
      t   = lo0(p_l + p_h)
      u   = t*lg2_h
      v   = (p_l - (t - p_h))*lg2 + t*lg2_l
      z   = u + v
      w   = v - (z - u)
      t   = z*z
      t1  = z - t*(P1 + t*(P2 + t*(P3 + t*(P4 + t*P5))))
      rr  = (z*t1)/(t1 - 2.0_r8) - (w + z*w)
      z   = 1.0_r8 - (rr - z)
      jj  = hiw(z) + n*1048576_i8
      IF (jj < 1048576_i8) THEN
         z = rm_scalbn(z, n)
      ELSE
         z = set_hi(z, jj)
      END IF
      res = s*z
   END FUNCTION rm_pow

!-----------------------------------------------------------------------
! trig kernels (k_sin.c, k_cos.c, k_tan.c)
!-----------------------------------------------------------------------

   PURE FUNCTION k_sin(x, y, iy) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x, y
      INTEGER, INTENT(IN) :: iy
      REAL(r8) :: res
      REAL(r8), PARAMETER :: S1 = -1.66666666666666324348e-01_r8
      REAL(r8), PARAMETER :: S2 =  8.33333333332248946124e-03_r8
      REAL(r8), PARAMETER :: S3 = -1.98412698298579493134e-04_r8
      REAL(r8), PARAMETER :: S4 =  2.75573137070700676789e-06_r8
      REAL(r8), PARAMETER :: S5 = -2.50507602534068634195e-08_r8
      REAL(r8), PARAMETER :: S6 =  1.58969099521155010221e-10_r8
      REAL(r8) :: z, r, v
      INTEGER(i8) :: ix

      ix = IAND(hiw(x), M31)
      IF (ix < INT(Z'3E400000', i8)) THEN
         res = x
         RETURN
      END IF
      z = x*x
      v = z*x
      r = S2 + z*(S3 + z*(S4 + z*(S5 + z*S6)))
      IF (iy == 0) THEN
         res = x + v*(S1 + z*r)
      ELSE
         res = x - ((z*(0.5_r8*y - v*r) - y) - v*S1)
      END IF
   END FUNCTION k_sin

   PURE FUNCTION k_cos(x, y) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x, y
      REAL(r8) :: res
      REAL(r8), PARAMETER :: C1 =  4.16666666666666019037e-02_r8
      REAL(r8), PARAMETER :: C2 = -1.38888888888741095749e-03_r8
      REAL(r8), PARAMETER :: C3 =  2.48015872894767294178e-05_r8
      REAL(r8), PARAMETER :: C4 = -2.75573143513906633035e-07_r8
      REAL(r8), PARAMETER :: C5 =  2.08757232129817482790e-09_r8
      REAL(r8), PARAMETER :: C6 = -1.13596475577881948265e-11_r8
      REAL(r8) :: a, hz, z, r, qx
      INTEGER(i8) :: ix

      ix = IAND(hiw(x), M31)
      IF (ix < INT(Z'3E400000', i8)) THEN
         res = 1.0_r8
         RETURN
      END IF
      z = x*x
      r = z*(C1 + z*(C2 + z*(C3 + z*(C4 + z*(C5 + z*C6)))))
      IF (ix < INT(Z'3FD33333', i8)) THEN
         res = 1.0_r8 - (0.5_r8*z - (z*r - x*y))
      ELSE
         IF (ix > INT(Z'3FE90000', i8)) THEN
            qx = 0.28125_r8
         ELSE
            qx = mkd(ix - INT(Z'00200000', i8), 0_i8)
         END IF
         hz  = 0.5_r8*z - qx
         a   = 1.0_r8 - qx
         res = a - (hz - (z*r - x*y))
      END IF
   END FUNCTION k_cos

   PURE FUNCTION k_tan(xin, yin, iy) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin, yin
      INTEGER, INTENT(IN) :: iy
      REAL(r8) :: res
      REAL(r8), PARAMETER :: pio4   = 7.85398163397448278999e-01_r8
      REAL(r8), PARAMETER :: pio4lo = 3.06161699786838301793e-17_r8
      REAL(r8) :: x, y, z, r, v, w, s, a, t
      INTEGER(i8) :: ix, hx

      x  = xin
      y  = yin
      hx = hiw(x)
      ix = IAND(hx, M31)
      IF (ix < INT(Z'3E300000', i8)) THEN
         IF (IOR(IOR(ix, low(x)), INT(iy + 1, i8)) == 0_i8) THEN
            res = 1.0_r8/fabs8(x)
         ELSE IF (iy == 1) THEN
            res = x
         ELSE
            ! -1/(x+y) carefully
            w = x + y
            z = lo0(w)
            v = y - (z - x)
            a = -1.0_r8/w
            t = lo0(a)
            s = 1.0_r8 + t*z
            res = t + a*(s + t*v)
         END IF
         RETURN
      END IF
      IF (ix >= INT(Z'3FE59428', i8)) THEN
         IF (BTEST(hx, 31)) THEN
            x = -x
            y = -y
         END IF
         z = pio4 - x
         w = pio4lo - y
         x = z + w
         y = 0.0_r8
      END IF
      z = x*x
      w = z*z
      r = TT(1) + w*(TT(3) + w*(TT(5) + w*(TT(7) + w*(TT(9) + w*TT(11)))))
      v = z*(TT(2) + w*(TT(4) + w*(TT(6) + w*(TT(8) + w*(TT(10) + w*TT(12))))))
      s = z*x
      r = y + z*(s*(r + v) + y)
      r = r + TT(0)*s
      w = x + r
      IF (ix >= INT(Z'3FE59428', i8)) THEN
         v = REAL(iy, r8)
         res = v - 2.0_r8*(x - ((w*w)/(w + v) - r))
         IF (BTEST(hx, 31)) res = -res
         RETURN
      END IF
      IF (iy == 1) THEN
         res = w
      ELSE
         ! -1/(x+r) accurately
         z = lo0(w)
         v = r - (z - x)
         a = -1.0_r8/w
         t = lo0(a)
         s = 1.0_r8 + t*z
         res = t + a*(s + t*v)
      END IF
   END FUNCTION k_tan

!-----------------------------------------------------------------------
! argument reduction (e_rem_pio2.c, k_rem_pio2.c with prec = 2)
!-----------------------------------------------------------------------

   PURE SUBROUTINE k_rem_pio2(x, y, e0, nx, nout)
!$omp declare target
      REAL(r8), INTENT(IN) :: x(0:2)
      REAL(r8), INTENT(OUT) :: y(0:1)
      INTEGER(i8), INTENT(IN) :: e0, nx
      INTEGER(i8), INTENT(OUT) :: nout
      REAL(r8), PARAMETER :: two24  = 1.67772160000000000000e+07_r8
      REAL(r8), PARAMETER :: twon24 = 5.96046447753906250000e-08_r8
      INTEGER(i8), PARAMETER :: jk = 4_i8, jp = 4_i8
      INTEGER(i8) :: jz, jx, jv, carry, n, iq(0:19), i, j, k, m, q0, ih
      REAL(r8) :: z, fw, f(0:19), fq(0:19), q(0:19)
      LOGICAL :: again

      iq = 0_i8
      f  = 0.0_r8
      fq = 0.0_r8
      q  = 0.0_r8
      jx = nx - 1_i8
      jv = (e0 - 3_i8)/24_i8
      IF (jv < 0_i8) jv = 0_i8
      q0 = e0 - 24_i8*(jv + 1_i8)

      j = jv - jx
      m = jx + jk
      DO i = 0_i8, m
         IF (j < 0_i8) THEN
            f(i) = 0.0_r8
         ELSE
            f(i) = REAL(two_over_pi(j), r8)
         END IF
         j = j + 1_i8
      END DO
      DO i = 0_i8, jk
         fw = 0.0_r8
         DO j = 0_i8, jx
            fw = fw + x(j)*f(jx + i - j)
         END DO
         q(i) = fw
      END DO

      jz = jk
      DO
         ! distill q into iq reversingly
         i = 0_i8
         j = jz
         z = q(jz)
         DO WHILE (j > 0_i8)
            fw    = REAL(INT(twon24*z, i8), r8)
            iq(i) = INT(z - two24*fw, i8)
            z     = q(j - 1_i8) + fw
            i = i + 1_i8
            j = j - 1_i8
         END DO

         ! compute n
         z  = rm_scalbn(z, q0)
         z  = z - 8.0_r8*REAL(FLOOR(z*0.125_r8, i8), r8)
         n  = INT(z, i8)
         z  = z - REAL(n, r8)
         ih = 0_i8
         IF (q0 > 0_i8) THEN
            i = ISHFT(iq(jz - 1_i8), -INT(24_i8 - q0))
            n = n + i
            iq(jz - 1_i8) = iq(jz - 1_i8) - ISHFT(i, INT(24_i8 - q0))
            ih = ISHFT(iq(jz - 1_i8), -INT(23_i8 - q0))
         ELSE IF (q0 == 0_i8) THEN
            ih = ISHFT(iq(jz - 1_i8), -23)
         ELSE IF (z >= 0.5_r8) THEN
            ih = 2_i8
         END IF

         IF (ih > 0_i8) THEN
            n = n + 1_i8
            carry = 0_i8
            DO i = 0_i8, jz - 1_i8
               j = iq(i)
               IF (carry == 0_i8) THEN
                  IF (j /= 0_i8) THEN
                     carry = 1_i8
                     iq(i) = INT(Z'1000000', i8) - j
                  END IF
               ELSE
                  iq(i) = INT(Z'FFFFFF', i8) - j
               END IF
            END DO
            IF (q0 == 1_i8) iq(jz - 1_i8) = IAND(iq(jz - 1_i8), INT(Z'7FFFFF', i8))
            IF (q0 == 2_i8) iq(jz - 1_i8) = IAND(iq(jz - 1_i8), INT(Z'3FFFFF', i8))
            IF (ih == 2_i8) THEN
               z = 1.0_r8 - z
               IF (carry /= 0_i8) z = z - rm_scalbn(1.0_r8, q0)
            END IF
         END IF

         ! check if recomputation is needed
         again = .FALSE.
         IF (z == 0.0_r8) THEN
            j = 0_i8
            DO i = jz - 1_i8, jk, -1_i8
               j = IOR(j, iq(i))
            END DO
            IF (j == 0_i8) THEN
               k = 1_i8
               DO WHILE (iq(jk - k) == 0_i8)
                  k = k + 1_i8
               END DO
               DO i = jz + 1_i8, jz + k
                  f(jx + i) = REAL(two_over_pi(jv + i), r8)
                  fw = 0.0_r8
                  DO j = 0_i8, jx
                     fw = fw + x(j)*f(jx + i - j)
                  END DO
                  q(i) = fw
               END DO
               jz = jz + k
               again = .TRUE.
            END IF
         END IF
         IF (.NOT. again) EXIT
      END DO

      ! chop off zero terms
      IF (z == 0.0_r8) THEN
         jz = jz - 1_i8
         q0 = q0 - 24_i8
         DO WHILE (iq(jz) == 0_i8)
            jz = jz - 1_i8
            q0 = q0 - 24_i8
         END DO
      ELSE
         z = rm_scalbn(z, -q0)
         IF (z >= two24) THEN
            fw = REAL(INT(twon24*z, i8), r8)
            iq(jz) = INT(z - two24*fw, i8)
            jz = jz + 1_i8
            q0 = q0 + 24_i8
            iq(jz) = INT(fw, i8)
         ELSE
            iq(jz) = INT(z, i8)
         END IF
      END IF

      ! convert integer chunks to floating point
      fw = rm_scalbn(1.0_r8, q0)
      DO i = jz, 0_i8, -1_i8
         q(i) = fw*REAL(iq(i), r8)
         fw   = fw*twon24
      END DO

      ! PIo2(0..jp) * q(jz..0)
      DO i = jz, 0_i8, -1_i8
         fw = 0.0_r8
         k  = 0_i8
         DO WHILE (k <= jp .AND. k <= jz - i)
            fw = fw + PIo2(k)*q(i + k)
            k  = k + 1_i8
         END DO
         fq(jz - i) = fw
      END DO

      ! compress fq into y (prec = 2)
      fw = 0.0_r8
      DO i = jz, 0_i8, -1_i8
         fw = fw + fq(i)
      END DO
      IF (ih == 0_i8) THEN
         y(0) = fw
      ELSE
         y(0) = -fw
      END IF
      fw = fq(0) - fw
      DO i = 1_i8, jz
         fw = fw + fq(i)
      END DO
      IF (ih == 0_i8) THEN
         y(1) = fw
      ELSE
         y(1) = -fw
      END IF
      nout = IAND(n, 7_i8)
   END SUBROUTINE k_rem_pio2

   PURE SUBROUTINE rem_pio2(x, y0, y1, n)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8), INTENT(OUT) :: y0, y1
      INTEGER(i8), INTENT(OUT) :: n
      REAL(r8), PARAMETER :: invpio2 = 6.36619772367581382433e-01_r8
      REAL(r8), PARAMETER :: pio2_1  = 1.57079632673412561417e+00_r8
      REAL(r8), PARAMETER :: pio2_1t = 6.07710050650619224932e-11_r8
      REAL(r8), PARAMETER :: pio2_2  = 6.07710050630396597660e-11_r8
      REAL(r8), PARAMETER :: pio2_2t = 2.02226624879595063154e-21_r8
      REAL(r8), PARAMETER :: pio2_3  = 2.02226624871116645580e-21_r8
      REAL(r8), PARAMETER :: pio2_3t = 8.47842766036889956997e-32_r8
      REAL(r8), PARAMETER :: two24   = 1.67772160000000000000e+07_r8
      REAL(r8) :: z, w, t, r, fn, tx(0:2), yy(0:1)
      INTEGER(i8) :: e0, i, j, nx, hx, ix
      LOGICAL :: xneg, more

      hx   = hiw(x)
      ix   = IAND(hx, M31)
      xneg = BTEST(hx, 31)
      IF (ix <= INT(Z'3FE921FB', i8)) THEN
         y0 = x
         y1 = 0.0_r8
         n  = 0_i8
         RETURN
      END IF
      IF (ix < INT(Z'4002D97C', i8)) THEN
         ! |x| < 3pi/4, n = +-1
         IF (.NOT. xneg) THEN
            z = x - pio2_1
            IF (ix /= INT(Z'3FF921FB', i8)) THEN
               y0 = z - pio2_1t
               y1 = (z - y0) - pio2_1t
            ELSE
               z  = z - pio2_2
               y0 = z - pio2_2t
               y1 = (z - y0) - pio2_2t
            END IF
            n = 1_i8
         ELSE
            z = x + pio2_1
            IF (ix /= INT(Z'3FF921FB', i8)) THEN
               y0 = z + pio2_1t
               y1 = (z - y0) + pio2_1t
            ELSE
               z  = z + pio2_2
               y0 = z + pio2_2t
               y1 = (z - y0) + pio2_2t
            END IF
            n = -1_i8
         END IF
         RETURN
      END IF
      IF (ix <= INT(Z'413921FB', i8)) THEN
         ! medium size, |x| <= 2**19*(pi/2)
         t  = fabs8(x)
         n  = INT(t*invpio2 + 0.5_r8, i8)
         fn = REAL(n, r8)
         r  = t - fn*pio2_1
         w  = fn*pio2_1t
         more = .TRUE.
         IF (n < 32_i8) THEN
            IF (ix /= npio2_hw(n)) more = .FALSE.
         END IF
         IF (.NOT. more) THEN
            ! quick check: no cancellation
            y0 = r - w
         ELSE
            j  = ISHFT(ix, -20)
            y0 = r - w
            i  = j - IAND(ISHFT(hiw(y0), -20), INT(Z'7FF', i8))
            IF (i > 16_i8) THEN
               ! second iteration, good to 118 bits
               t  = r
               w  = fn*pio2_2
               r  = t - w
               w  = fn*pio2_2t - ((t - r) - w)
               y0 = r - w
               i  = j - IAND(ISHFT(hiw(y0), -20), INT(Z'7FF', i8))
               IF (i > 49_i8) THEN
                  ! third iteration, 151 bits
                  t  = r
                  w  = fn*pio2_3
                  r  = t - w
                  w  = fn*pio2_3t - ((t - r) - w)
                  y0 = r - w
               END IF
            END IF
         END IF
         y1 = (r - y0) - w
         IF (xneg) THEN
            y0 = -y0
            y1 = -y1
            n  = -n
         END IF
         RETURN
      END IF
      IF (ix >= HI_INF) THEN
         y0 = nan8()
         y1 = nan8()
         n  = 0_i8
         RETURN
      END IF
      ! large arguments: z = scalbn(|x|, ilogb(x)-23)
      e0 = ISHFT(ix, -20) - 1046_i8
      z  = mkd(ix - ISHFT(e0, 20), low(x))
      DO i = 0_i8, 1_i8
         tx(i) = REAL(INT(z, i8), r8)
         z     = (z - tx(i))*two24
      END DO
      tx(2) = z
      nx = 3_i8
      DO WHILE (tx(nx - 1_i8) == 0.0_r8)
         nx = nx - 1_i8
      END DO
      CALL k_rem_pio2(tx, yy, e0, nx, n)
      y0 = yy(0)
      y1 = yy(1)
      IF (xneg) THEN
         y0 = -y0
         y1 = -y1
         n  = -n
      END IF
   END SUBROUTINE rem_pio2

!-----------------------------------------------------------------------
! sin, cos, tan (s_sin.c, s_cos.c, s_tan.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_sin(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res, y0, y1
      INTEGER(i8) :: ix, n

      ix = IAND(hiw(x), M31)
      IF (ix <= INT(Z'3FE921FB', i8)) THEN
         res = k_sin(x, 0.0_r8, 0)
      ELSE IF (ix >= HI_INF) THEN
         res = nan8()
      ELSE
         CALL rem_pio2(x, y0, y1, n)
         SELECT CASE (IAND(n, 3_i8))
         CASE (0_i8)
            res =  k_sin(y0, y1, 1)
         CASE (1_i8)
            res =  k_cos(y0, y1)
         CASE (2_i8)
            res = -k_sin(y0, y1, 1)
         CASE DEFAULT
            res = -k_cos(y0, y1)
         END SELECT
      END IF
   END FUNCTION rm_sin

   PURE FUNCTION rm_cos(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res, y0, y1
      INTEGER(i8) :: ix, n

      ix = IAND(hiw(x), M31)
      IF (ix <= INT(Z'3FE921FB', i8)) THEN
         res = k_cos(x, 0.0_r8)
      ELSE IF (ix >= HI_INF) THEN
         res = nan8()
      ELSE
         CALL rem_pio2(x, y0, y1, n)
         SELECT CASE (IAND(n, 3_i8))
         CASE (0_i8)
            res =  k_cos(y0, y1)
         CASE (1_i8)
            res = -k_sin(y0, y1, 1)
         CASE (2_i8)
            res = -k_cos(y0, y1)
         CASE DEFAULT
            res =  k_sin(y0, y1, 1)
         END SELECT
      END IF
   END FUNCTION rm_cos

   PURE FUNCTION rm_tan(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res, y0, y1
      INTEGER(i8) :: ix, n

      ix = IAND(hiw(x), M31)
      IF (ix <= INT(Z'3FE921FB', i8)) THEN
         res = k_tan(x, 0.0_r8, 1)
      ELSE IF (ix >= HI_INF) THEN
         res = nan8()
      ELSE
         CALL rem_pio2(x, y0, y1, n)
         res = k_tan(y0, y1, INT(1_i8 - 2_i8*IAND(n, 1_i8)))
      END IF
   END FUNCTION rm_tan

!-----------------------------------------------------------------------
! atan, atan2 (s_atan.c, e_atan2.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_atan(xin) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin
      REAL(r8) :: res
      REAL(r8) :: x, w, s1, s2, z
      INTEGER(i8) :: ix, hx, id

      x  = xin
      hx = hiw(x)
      ix = IAND(hx, M31)
      IF (ix >= INT(Z'44100000', i8)) THEN
         ! |x| >= 2**66
         IF (ix > HI_INF .OR. (ix == HI_INF .AND. low(x) /= 0_i8)) THEN
            res = nan8()
         ELSE IF (.NOT. BTEST(hx, 31)) THEN
            res = atanhi(3) + atanlo(3)
         ELSE
            res = -atanhi(3) - atanlo(3)
         END IF
         RETURN
      END IF
      IF (ix < INT(Z'3FDC0000', i8)) THEN
         ! |x| < 0.4375
         IF (ix < INT(Z'3E200000', i8)) THEN
            res = x
            RETURN
         END IF
         id = -1_i8
      ELSE
         x = fabs8(x)
         IF (ix < INT(Z'3FF30000', i8)) THEN
            IF (ix < INT(Z'3FE60000', i8)) THEN
               id = 0_i8
               x  = (2.0_r8*x - 1.0_r8)/(2.0_r8 + x)
            ELSE
               id = 1_i8
               x  = (x - 1.0_r8)/(x + 1.0_r8)
            END IF
         ELSE
            IF (ix < INT(Z'40038000', i8)) THEN
               id = 2_i8
               x  = (x - 1.5_r8)/(1.0_r8 + 1.5_r8*x)
            ELSE
               id = 3_i8
               x  = -1.0_r8/x
            END IF
         END IF
      END IF
      z  = x*x
      w  = z*z
      s1 = z*(aT(0) + w*(aT(2) + w*(aT(4) + w*(aT(6) + w*(aT(8) + w*aT(10))))))
      s2 = w*(aT(1) + w*(aT(3) + w*(aT(5) + w*(aT(7) + w*aT(9)))))
      IF (id < 0_i8) THEN
         res = x - x*(s1 + s2)
      ELSE
         z = atanhi(id) - ((x*(s1 + s2) - atanlo(id)) - x)
         IF (BTEST(hx, 31)) THEN
            res = -z
         ELSE
            res = z
         END IF
      END IF
   END FUNCTION rm_atan

   PURE FUNCTION rm_atan2(y, x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: y, x
      REAL(r8) :: res
      REAL(r8), PARAMETER :: pi_o_4 = 7.8539816339744827900e-01_r8
      REAL(r8), PARAMETER :: pi_o_2 = 1.5707963267948965580e+00_r8
      REAL(r8), PARAMETER :: pi     = 3.1415926535897931160e+00_r8
      REAL(r8), PARAMETER :: pi_lo  = 1.2246467991473531772e-16_r8
      REAL(r8) :: z
      INTEGER(i8) :: k, m, hx, hy, ix, iy, lx, ly

      hx = hiw(x)
      ix = IAND(hx, M31)
      lx = low(x)
      hy = hiw(y)
      iy = IAND(hy, M31)
      ly = low(y)
      IF (ix > HI_INF .OR. (ix == HI_INF .AND. lx /= 0_i8) .OR.   &
          iy > HI_INF .OR. (iy == HI_INF .AND. ly /= 0_i8)) THEN
         res = nan8()
         RETURN
      END IF
      IF (hx == INT(Z'3FF00000', i8) .AND. lx == 0_i8) THEN
         ! x = 1.0
         res = rm_atan(y)
         RETURN
      END IF
      ! m = 2*sign(x) + sign(y)
      m = IOR(IAND(ISHFT(hy, -31), 1_i8), IAND(ISHFT(hx, -30), 2_i8))

      ! y = 0
      IF (IOR(iy, ly) == 0_i8) THEN
         SELECT CASE (m)
         CASE (0_i8, 1_i8)
            res = y
         CASE (2_i8)
            res = pi
         CASE DEFAULT
            res = -pi
         END SELECT
         RETURN
      END IF
      ! x = 0
      IF (IOR(ix, lx) == 0_i8) THEN
         IF (BTEST(hy, 31)) THEN
            res = -pi_o_2
         ELSE
            res = pi_o_2
         END IF
         RETURN
      END IF
      ! x = inf
      IF (ix == HI_INF) THEN
         IF (iy == HI_INF) THEN
            SELECT CASE (m)
            CASE (0_i8)
               res = pi_o_4
            CASE (1_i8)
               res = -pi_o_4
            CASE (2_i8)
               res = 3.0_r8*pi_o_4
            CASE DEFAULT
               res = -3.0_r8*pi_o_4
            END SELECT
         ELSE
            SELECT CASE (m)
            CASE (0_i8)
               res = 0.0_r8
            CASE (1_i8)
               res = -0.0_r8
            CASE (2_i8)
               res = pi
            CASE DEFAULT
               res = -pi
            END SELECT
         END IF
         RETURN
      END IF
      ! y = inf
      IF (iy == HI_INF) THEN
         IF (BTEST(hy, 31)) THEN
            res = -pi_o_2
         ELSE
            res = pi_o_2
         END IF
         RETURN
      END IF

      ! y/x
      k = asr(iy - ix, 20)
      IF (k > 60_i8) THEN
         z = pi_o_2 + 0.5_r8*pi_lo
      ELSE IF (BTEST(hx, 31) .AND. k < -60_i8) THEN
         z = 0.0_r8
      ELSE
         z = rm_atan(fabs8(y/x))
      END IF
      SELECT CASE (m)
      CASE (0_i8)
         res = z
      CASE (1_i8)
         res = -z
      CASE (2_i8)
         res = pi - (z - pi_lo)
      CASE DEFAULT
         res = (z - pi_lo) - pi
      END SELECT
   END FUNCTION rm_atan2

!-----------------------------------------------------------------------
! asin, acos (e_asin.c, e_acos.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_asin(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res
      REAL(r8), PARAMETER :: pio2_hi = 1.57079632679489655800e+00_r8
      REAL(r8), PARAMETER :: pio2_lo = 6.12323399573676603587e-17_r8
      REAL(r8), PARAMETER :: pio4_hi = 7.85398163397448278999e-01_r8
      REAL(r8), PARAMETER :: pS0 =  1.66666666666666657415e-01_r8
      REAL(r8), PARAMETER :: pS1 = -3.25565818622400915405e-01_r8
      REAL(r8), PARAMETER :: pS2 =  2.01212532134862925881e-01_r8
      REAL(r8), PARAMETER :: pS3 = -4.00555345006794114027e-02_r8
      REAL(r8), PARAMETER :: pS4 =  7.91534994289814532176e-04_r8
      REAL(r8), PARAMETER :: pS5 =  3.47933107596021167570e-05_r8
      REAL(r8), PARAMETER :: qS1 = -2.40339491173441421878e+00_r8
      REAL(r8), PARAMETER :: qS2 =  2.02094576023350569471e+00_r8
      REAL(r8), PARAMETER :: qS3 = -6.88283971605453293030e-01_r8
      REAL(r8), PARAMETER :: qS4 =  7.70381505559019352791e-02_r8
      REAL(r8) :: t, w, p, q, c, r, s
      INTEGER(i8) :: hx, ix

      hx = hiw(x)
      ix = IAND(hx, M31)
      IF (ix >= INT(Z'3FF00000', i8)) THEN
         IF (IOR(ix - INT(Z'3FF00000', i8), low(x)) == 0_i8) THEN
            res = x*pio2_hi + x*pio2_lo
         ELSE
            res = nan8()
         END IF
         RETURN
      ELSE IF (ix < INT(Z'3FE00000', i8)) THEN
         IF (ix < INT(Z'3E400000', i8)) THEN
            res = x
            RETURN
         END IF
         t = x*x
         p = t*(pS0 + t*(pS1 + t*(pS2 + t*(pS3 + t*(pS4 + t*pS5)))))
         q = 1.0_r8 + t*(qS1 + t*(qS2 + t*(qS3 + t*qS4)))
         w = p/q
         res = x + x*w
         RETURN
      END IF
      ! 1 > |x| >= 0.5
      w = 1.0_r8 - fabs8(x)
      t = w*0.5_r8
      p = t*(pS0 + t*(pS1 + t*(pS2 + t*(pS3 + t*(pS4 + t*pS5)))))
      q = 1.0_r8 + t*(qS1 + t*(qS2 + t*(qS3 + t*qS4)))
      s = SQRT(t)
      IF (ix >= INT(Z'3FEF3333', i8)) THEN
         w = p/q
         t = pio2_hi - (2.0_r8*(s + s*w) - pio2_lo)
      ELSE
         w = lo0(s)
         c = (t - w*w)/(s + w)
         r = p/q
         p = (2.0_r8*s)*r - (pio2_lo - 2.0_r8*c)
         q = pio4_hi - 2.0_r8*w
         t = pio4_hi - (p - q)
      END IF
      IF (.NOT. BTEST(hx, 31)) THEN
         res = t
      ELSE
         res = -t
      END IF
   END FUNCTION rm_asin

   PURE FUNCTION rm_acos(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res
      REAL(r8), PARAMETER :: pi      = 3.14159265358979311600e+00_r8
      REAL(r8), PARAMETER :: pio2_hi = 1.57079632679489655800e+00_r8
      REAL(r8), PARAMETER :: pio2_lo = 6.12323399573676603587e-17_r8
      REAL(r8), PARAMETER :: pS0 =  1.66666666666666657415e-01_r8
      REAL(r8), PARAMETER :: pS1 = -3.25565818622400915405e-01_r8
      REAL(r8), PARAMETER :: pS2 =  2.01212532134862925881e-01_r8
      REAL(r8), PARAMETER :: pS3 = -4.00555345006794114027e-02_r8
      REAL(r8), PARAMETER :: pS4 =  7.91534994289814532176e-04_r8
      REAL(r8), PARAMETER :: pS5 =  3.47933107596021167570e-05_r8
      REAL(r8), PARAMETER :: qS1 = -2.40339491173441421878e+00_r8
      REAL(r8), PARAMETER :: qS2 =  2.02094576023350569471e+00_r8
      REAL(r8), PARAMETER :: qS3 = -6.88283971605453293030e-01_r8
      REAL(r8), PARAMETER :: qS4 =  7.70381505559019352791e-02_r8
      REAL(r8) :: z, p, q, r, w, s, c, df
      INTEGER(i8) :: hx, ix

      hx = hiw(x)
      ix = IAND(hx, M31)
      IF (ix >= INT(Z'3FF00000', i8)) THEN
         IF (IOR(ix - INT(Z'3FF00000', i8), low(x)) == 0_i8) THEN
            IF (.NOT. BTEST(hx, 31)) THEN
               res = 0.0_r8
            ELSE
               res = pi + 2.0_r8*pio2_lo
            END IF
         ELSE
            res = nan8()
         END IF
         RETURN
      END IF
      IF (ix < INT(Z'3FE00000', i8)) THEN
         IF (ix <= INT(Z'3C600000', i8)) THEN
            res = pio2_hi + pio2_lo
            RETURN
         END IF
         z = x*x
         p = z*(pS0 + z*(pS1 + z*(pS2 + z*(pS3 + z*(pS4 + z*pS5)))))
         q = 1.0_r8 + z*(qS1 + z*(qS2 + z*(qS3 + z*qS4)))
         r = p/q
         res = pio2_hi - (x - (pio2_lo - x*r))
      ELSE IF (BTEST(hx, 31)) THEN
         ! x < -0.5
         z = (1.0_r8 + x)*0.5_r8
         p = z*(pS0 + z*(pS1 + z*(pS2 + z*(pS3 + z*(pS4 + z*pS5)))))
         q = 1.0_r8 + z*(qS1 + z*(qS2 + z*(qS3 + z*qS4)))
         s = SQRT(z)
         r = p/q
         w = r*s - pio2_lo
         res = pi - 2.0_r8*(s + w)
      ELSE
         ! x > 0.5
         z  = (1.0_r8 - x)*0.5_r8
         s  = SQRT(z)
         df = lo0(s)
         c  = (z - df*df)/(s + df)
         p  = z*(pS0 + z*(pS1 + z*(pS2 + z*(pS3 + z*(pS4 + z*pS5)))))
         q  = 1.0_r8 + z*(qS1 + z*(qS2 + z*(qS3 + z*qS4)))
         r  = p/q
         w  = r*s + c
         res = 2.0_r8*(df + w)
      END IF
   END FUNCTION rm_acos

!-----------------------------------------------------------------------
! expm1, sinh, cosh, tanh (s_expm1.c, e_sinh.c, e_cosh.c, s_tanh.c)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_expm1(xin) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: xin
      REAL(r8) :: res
      REAL(r8), PARAMETER :: o_threshold = 7.09782712893383973096e+02_r8
      REAL(r8), PARAMETER :: ln2_hi = 6.93147180369123816490e-01_r8
      REAL(r8), PARAMETER :: ln2_lo = 1.90821492927058770002e-10_r8
      REAL(r8), PARAMETER :: invln2 = 1.44269504088896338700e+00_r8
      REAL(r8), PARAMETER :: Q1 = -3.33333333333331316428e-02_r8
      REAL(r8), PARAMETER :: Q2 =  1.58730158725481460165e-03_r8
      REAL(r8), PARAMETER :: Q3 = -7.93650757867487942473e-05_r8
      REAL(r8), PARAMETER :: Q4 =  4.00821782732936239552e-06_r8
      REAL(r8), PARAMETER :: Q5 = -2.01099218183624371326e-07_r8
      REAL(r8) :: x, y, hi, lo, c, t, e, hxs, hfx, r1
      INTEGER(i8) :: k, hx
      LOGICAL :: neg

      x   = xin
      hx  = hiw(x)
      neg = BTEST(hx, 31)
      hx  = IAND(hx, M31)
      c   = 0.0_r8
      k   = 0_i8

      IF (hx >= INT(Z'4043687A', i8)) THEN
         ! |x| >= 56*ln2
         IF (hx >= INT(Z'40862E42', i8)) THEN
            IF (hx >= HI_INF) THEN
               IF (IOR(IAND(hx, INT(Z'000FFFFF', i8)), low(x)) /= 0_i8) THEN
                  res = nan8()
               ELSE IF (.NOT. neg) THEN
                  res = x
               ELSE
                  res = -1.0_r8
               END IF
               RETURN
            END IF
            IF (x > o_threshold) THEN
               res = inf8()
               RETURN
            END IF
         END IF
         IF (neg) THEN
            res = -1.0_r8
            RETURN
         END IF
      END IF

      IF (hx > INT(Z'3FD62E42', i8)) THEN
         IF (hx < INT(Z'3FF0A2B2', i8)) THEN
            IF (.NOT. neg) THEN
               hi = x - ln2_hi
               lo = ln2_lo
               k  = 1_i8
            ELSE
               hi = x + ln2_hi
               lo = -ln2_lo
               k  = -1_i8
            END IF
         ELSE
            IF (.NOT. neg) THEN
               k = INT(invln2*x + 0.5_r8, i8)
            ELSE
               k = INT(invln2*x - 0.5_r8, i8)
            END IF
            t  = REAL(k, r8)
            hi = x - t*ln2_hi
            lo = t*ln2_lo
         END IF
         x = hi - lo
         c = (hi - x) - lo
      ELSE IF (hx < INT(Z'3C900000', i8)) THEN
         res = x
         RETURN
      ELSE
         k = 0_i8
      END IF

      hfx = 0.5_r8*x
      hxs = x*hfx
      r1  = 1.0_r8 + hxs*(Q1 + hxs*(Q2 + hxs*(Q3 + hxs*(Q4 + hxs*Q5))))
      t   = 3.0_r8 - r1*hfx
      e   = hxs*((r1 - t)/(6.0_r8 - x*t))
      IF (k == 0_i8) THEN
         res = x - (x*e - hxs)
         RETURN
      END IF
      e = (x*(e - c) - c)
      e = e - hxs
      IF (k == -1_i8) THEN
         res = 0.5_r8*(x - e) - 0.5_r8
         RETURN
      END IF
      IF (k == 1_i8) THEN
         IF (x < -0.25_r8) THEN
            res = -2.0_r8*(e - (x + 0.5_r8))
         ELSE
            res = 1.0_r8 + 2.0_r8*(x - e)
         END IF
         RETURN
      END IF
      IF (k <= -2_i8 .OR. k > 56_i8) THEN
         y   = 1.0_r8 - (e - x)
         y   = set_hi(y, hiw(y) + k*1048576_i8)
         res = y - 1.0_r8
         RETURN
      END IF
      IF (k < 20_i8) THEN
         t = mkd(INT(Z'3FF00000', i8) - ISHFT(INT(Z'200000', i8), -INT(k)), 0_i8)
         y = t - (e - x)
         y = set_hi(y, hiw(y) + k*1048576_i8)
      ELSE
         t = mkd(ISHFT(1023_i8 - k, 20), 0_i8)
         y = x - (e + t)
         y = y + 1.0_r8
         y = set_hi(y, hiw(y) + k*1048576_i8)
      END IF
      res = y
   END FUNCTION rm_expm1

   PURE FUNCTION rm_sinh(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res
      REAL(r8) :: t, w, h
      INTEGER(i8) :: ix, jx, lx

      jx = hiw(x)
      ix = IAND(jx, M31)
      IF (ix >= HI_INF) THEN
         res = canon8(x + x)
         RETURN
      END IF
      h = 0.5_r8
      IF (BTEST(jx, 31)) h = -h
      IF (ix < INT(Z'40360000', i8)) THEN
         ! |x| < 22
         IF (ix < INT(Z'3E300000', i8)) THEN
            res = x
            RETURN
         END IF
         t = rm_expm1(fabs8(x))
         IF (ix < INT(Z'3FF00000', i8)) THEN
            res = h*(2.0_r8*t - (t*t)/(t + 1.0_r8))
         ELSE
            res = h*(t + t/(t + 1.0_r8))
         END IF
         RETURN
      END IF
      IF (ix < INT(Z'40862E42', i8)) THEN
         res = h*rm_exp(fabs8(x))
         RETURN
      END IF
      lx = low(x)
      IF (ix < INT(Z'408633CE', i8) .OR. (ix == INT(Z'408633CE', i8) .AND. lx <= INT(Z'8FB9F87D', i8))) THEN
         w = rm_exp(0.5_r8*fabs8(x))
         t = h*w
         res = t*w
         RETURN
      END IF
      res = copysign8(inf8(), x)
   END FUNCTION rm_sinh

   PURE FUNCTION rm_cosh(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res
      REAL(r8) :: t, w
      INTEGER(i8) :: ix, lx

      ix = IAND(hiw(x), M31)
      IF (ix >= HI_INF) THEN
         res = canon8(x*x)
         RETURN
      END IF
      IF (ix < INT(Z'3FD62E43', i8)) THEN
         ! |x| < 0.5*ln2
         t = rm_expm1(fabs8(x))
         w = 1.0_r8 + t
         IF (ix < INT(Z'3C800000', i8)) THEN
            res = w
         ELSE
            res = 1.0_r8 + (t*t)/(w + w)
         END IF
         RETURN
      END IF
      IF (ix < INT(Z'40360000', i8)) THEN
         t = rm_exp(fabs8(x))
         res = 0.5_r8*t + 0.5_r8/t
         RETURN
      END IF
      IF (ix < INT(Z'40862E42', i8)) THEN
         res = 0.5_r8*rm_exp(fabs8(x))
         RETURN
      END IF
      lx = low(x)
      IF (ix < INT(Z'408633CE', i8) .OR. (ix == INT(Z'408633CE', i8) .AND. lx <= INT(Z'8FB9F87D', i8))) THEN
         w = rm_exp(0.5_r8*fabs8(x))
         t = 0.5_r8*w
         res = t*w
         RETURN
      END IF
      res = inf8()
   END FUNCTION rm_cosh

   PURE FUNCTION rm_tanh(x) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: res
      REAL(r8) :: t, z
      INTEGER(i8) :: jx, ix

      jx = hiw(x)
      ix = IAND(jx, M31)
      IF (ix >= HI_INF) THEN
         IF (IOR(IAND(ix, INT(Z'000FFFFF', i8)), low(x)) /= 0_i8) THEN
            res = nan8()
         ELSE IF (.NOT. BTEST(jx, 31)) THEN
            res = 1.0_r8
         ELSE
            res = -1.0_r8
         END IF
         RETURN
      END IF
      IF (ix < INT(Z'40360000', i8)) THEN
         ! |x| < 22
         IF (ix < INT(Z'3C800000', i8)) THEN
            res = x*(1.0_r8 + x)
            RETURN
         END IF
         IF (ix >= INT(Z'3FF00000', i8)) THEN
            t = rm_expm1(2.0_r8*fabs8(x))
            z = 1.0_r8 - 2.0_r8/(t + 2.0_r8)
         ELSE
            t = rm_expm1(-2.0_r8*fabs8(x))
            z = -t/(t + 2.0_r8)
         END IF
      ELSE
         z = 1.0_r8
      END IF
      IF (.NOT. BTEST(jx, 31)) THEN
         res = z
      ELSE
         res = -z
      END IF
   END FUNCTION rm_tanh

!-----------------------------------------------------------------------
! exact fmod (result is exactly representable; same value as C fmod)
!-----------------------------------------------------------------------

   PURE FUNCTION rm_fmod(x, y) RESULT(res)
!$omp declare target
      REAL(r8), INTENT(IN) :: x, y
      REAL(r8) :: res
      INTEGER(i8) :: ax, ay, ex, ey, mx, my, rr, d, s

      ax = IAND(TRANSFER(x, 0_i8), ABS_MASK)
      ay = IAND(TRANSFER(y, 0_i8), ABS_MASK)
      IF (ax > INF_BITS .OR. ay > INF_BITS .OR. ax == INF_BITS .OR. ay == 0_i8) THEN
         res = nan8()
         RETURN
      END IF
      IF (ay == INF_BITS .OR. ax < ay) THEN
         res = x
         RETURN
      END IF
      IF (ax == ay) THEN
         res = copysign8(0.0_r8, x)
         RETURN
      END IF
      ex = ISHFT(ax, -52)
      mx = IAND(ax, MANT52)
      IF (ex == 0_i8) THEN
         ex = 1_i8
      ELSE
         mx = IOR(mx, HIDDEN52)
      END IF
      ey = ISHFT(ay, -52)
      my = IAND(ay, MANT52)
      IF (ey == 0_i8) THEN
         ey = 1_i8
      ELSE
         my = IOR(my, HIDDEN52)
      END IF
      ! |x| = mx*2**(ex-1075), |y| = my*2**(ey-1075), ex >= ey
      rr = MOD(mx, my)
      d  = ex - ey
      DO WHILE (d > 0_i8 .AND. rr /= 0_i8)
         s  = MIN(d, 10_i8)
         rr = MOD(ISHFT(rr, INT(s)), my)
         d  = d - s
      END DO
      IF (rr == 0_i8) THEN
         res = copysign8(0.0_r8, x)
      ELSE
         res = copysign8(rm_scalbn(REAL(rr, r8), ey - 1075_i8), x)
      END IF
   END FUNCTION rm_fmod

!-----------------------------------------------------------------------
! Public specifics: REAL(4)
!-----------------------------------------------------------------------

   ELEMENTAL FUNCTION rp_exp_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_exp(REAL(x, r8)))
#else
      r = EXP(x)
#endif
   END FUNCTION rp_exp_r4

   ELEMENTAL FUNCTION rp_log_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_log(REAL(x, r8)))
#else
      r = LOG(x)
#endif
   END FUNCTION rp_log_r4

   ELEMENTAL FUNCTION rp_log10_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_log10(REAL(x, r8)))
#else
      r = LOG10(x)
#endif
   END FUNCTION rp_log10_r4

   ELEMENTAL FUNCTION rp_sin_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_sin(REAL(x, r8)))
#else
      r = SIN(x)
#endif
   END FUNCTION rp_sin_r4

   ELEMENTAL FUNCTION rp_cos_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_cos(REAL(x, r8)))
#else
      r = COS(x)
#endif
   END FUNCTION rp_cos_r4

   ELEMENTAL FUNCTION rp_tan_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_tan(REAL(x, r8)))
#else
      r = TAN(x)
#endif
   END FUNCTION rp_tan_r4

   ELEMENTAL FUNCTION rp_asin_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_asin(REAL(x, r8)))
#else
      r = ASIN(x)
#endif
   END FUNCTION rp_asin_r4

   ELEMENTAL FUNCTION rp_acos_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_acos(REAL(x, r8)))
#else
      r = ACOS(x)
#endif
   END FUNCTION rp_acos_r4

   ELEMENTAL FUNCTION rp_atan_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_atan(REAL(x, r8)))
#else
      r = ATAN(x)
#endif
   END FUNCTION rp_atan_r4

   ELEMENTAL FUNCTION rp_atan2_r4(y, x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: y, x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_atan2(REAL(y, r8), REAL(x, r8)))
#else
      r = ATAN2(y, x)
#endif
   END FUNCTION rp_atan2_r4

   ELEMENTAL FUNCTION rp_sinh_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_sinh(REAL(x, r8)))
#else
      r = SINH(x)
#endif
   END FUNCTION rp_sinh_r4

   ELEMENTAL FUNCTION rp_cosh_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_cosh(REAL(x, r8)))
#else
      r = COSH(x)
#endif
   END FUNCTION rp_cosh_r4

   ELEMENTAL FUNCTION rp_tanh_r4(x) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_tanh(REAL(x, r8)))
#else
      r = TANH(x)
#endif
   END FUNCTION rp_tanh_r4

   ELEMENTAL FUNCTION rp_pow_r4(x, y) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x, y
      REAL(r4) :: r
#ifdef REPRO_MATH
      IF (y == 2.0_r4) THEN
         ! identical to the general path: the double product of two
         ! REAL(4) values is exact, so rounding it equals x*x in REAL(4)
         r = x*x
         IF (r /= r) r = TRANSFER(NAN4_BITS, 1.0_r4)
      ELSE
         r = to_r4(rm_pow(REAL(x, r8), REAL(y, r8)))
      END IF
#else
      r = x**y
#endif
   END FUNCTION rp_pow_r4

   ELEMENTAL FUNCTION rp_mod_r4(a, p) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: a, p
      REAL(r4) :: r
#ifdef REPRO_MATH
      r = to_r4(rm_fmod(REAL(a, r8), REAL(p, r8)))
#else
      r = MOD(a, p)
#endif
   END FUNCTION rp_mod_r4

!-----------------------------------------------------------------------
! Public specifics: REAL(8)
!-----------------------------------------------------------------------

   ELEMENTAL FUNCTION rp_exp_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_exp(x))
#else
      r = EXP(x)
#endif
   END FUNCTION rp_exp_r8

   ELEMENTAL FUNCTION rp_log_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_log(x))
#else
      r = LOG(x)
#endif
   END FUNCTION rp_log_r8

   ELEMENTAL FUNCTION rp_log10_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_log10(x))
#else
      r = LOG10(x)
#endif
   END FUNCTION rp_log10_r8

   ELEMENTAL FUNCTION rp_sin_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_sin(x))
#else
      r = SIN(x)
#endif
   END FUNCTION rp_sin_r8

   ELEMENTAL FUNCTION rp_cos_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_cos(x))
#else
      r = COS(x)
#endif
   END FUNCTION rp_cos_r8

   ELEMENTAL FUNCTION rp_tan_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_tan(x))
#else
      r = TAN(x)
#endif
   END FUNCTION rp_tan_r8

   ELEMENTAL FUNCTION rp_asin_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_asin(x))
#else
      r = ASIN(x)
#endif
   END FUNCTION rp_asin_r8

   ELEMENTAL FUNCTION rp_acos_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_acos(x))
#else
      r = ACOS(x)
#endif
   END FUNCTION rp_acos_r8

   ELEMENTAL FUNCTION rp_atan_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_atan(x))
#else
      r = ATAN(x)
#endif
   END FUNCTION rp_atan_r8

   ELEMENTAL FUNCTION rp_atan2_r8(y, x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: y, x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_atan2(y, x))
#else
      r = ATAN2(y, x)
#endif
   END FUNCTION rp_atan2_r8

   ELEMENTAL FUNCTION rp_sinh_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_sinh(x))
#else
      r = SINH(x)
#endif
   END FUNCTION rp_sinh_r8

   ELEMENTAL FUNCTION rp_cosh_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_cosh(x))
#else
      r = COSH(x)
#endif
   END FUNCTION rp_cosh_r8

   ELEMENTAL FUNCTION rp_tanh_r8(x) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_tanh(x))
#else
      r = TANH(x)
#endif
   END FUNCTION rp_tanh_r8

   ELEMENTAL FUNCTION rp_pow_r8(x, y) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x, y
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = canon8(rm_pow(x, y))
#else
      r = x**y
#endif
   END FUNCTION rp_pow_r8

   ELEMENTAL FUNCTION rp_mod_r8(a, p) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: a, p
      REAL(r8) :: r
#ifdef REPRO_MATH
      r = rm_fmod(a, p)
#else
      r = MOD(a, p)
#endif
   END FUNCTION rp_mod_r8

!-----------------------------------------------------------------------
! Public specifics: mixed kinds and integers (Fortran conversion rules)
!-----------------------------------------------------------------------

   ELEMENTAL FUNCTION rp_pow_r4r8(x, y) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r8), INTENT(IN) :: y
      REAL(r8) :: r
      r = rp_pow_r8(REAL(x, r8), y)
   END FUNCTION rp_pow_r4r8

   ELEMENTAL FUNCTION rp_pow_r8r4(x, y) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      REAL(r4), INTENT(IN) :: y
      REAL(r8) :: r
      r = rp_pow_r8(x, REAL(y, r8))
   END FUNCTION rp_pow_r8r4

   ELEMENTAL FUNCTION rp_pow_i4r4(x, y) RESULT(r)
!$omp declare target
      INTEGER(i4), INTENT(IN) :: x
      REAL(r4), INTENT(IN) :: y
      REAL(r4) :: r
      r = rp_pow_r4(REAL(x, r4), y)
   END FUNCTION rp_pow_i4r4

   ELEMENTAL FUNCTION rp_pow_i4r8(x, y) RESULT(r)
!$omp declare target
      INTEGER(i4), INTENT(IN) :: x
      REAL(r8), INTENT(IN) :: y
      REAL(r8) :: r
      r = rp_pow_r8(REAL(x, r8), y)
   END FUNCTION rp_pow_i4r8

   ! Integer exponents: evaluated exactly as the original expression x**n.
   ELEMENTAL FUNCTION rp_pow_r4i4(x, n) RESULT(r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      INTEGER(i4), INTENT(IN) :: n
      REAL(r4) :: r
      r = x**n
   END FUNCTION rp_pow_r4i4

   ELEMENTAL FUNCTION rp_pow_r8i4(x, n) RESULT(r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x
      INTEGER(i4), INTENT(IN) :: n
      REAL(r8) :: r
      r = x**n
   END FUNCTION rp_pow_r8i4

   ELEMENTAL FUNCTION rp_pow_i4i4(x, n) RESULT(r)
!$omp declare target
      INTEGER(i4), INTENT(IN) :: x, n
      INTEGER(i4) :: r
      r = x**n
   END FUNCTION rp_pow_i4i4

   ELEMENTAL FUNCTION rp_mod_i4(a, p) RESULT(r)
!$omp declare target
      INTEGER(i4), INTENT(IN) :: a, p
      INTEGER(i4) :: r
      r = MOD(a, p)
   END FUNCTION rp_mod_i4

   ELEMENTAL FUNCTION rp_mod_i8(a, p) RESULT(r)
!$omp declare target
      INTEGER(i8), INTENT(IN) :: a, p
      INTEGER(i8) :: r
      r = MOD(a, p)
   END FUNCTION rp_mod_i8

END MODULE module_repro_math
