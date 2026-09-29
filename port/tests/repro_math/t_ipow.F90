! T-IPOW (plan.md P0.6): integer powers, host vs device.
!
! rp_subst.py leaves integer-literal exponents alone; the compilers expand
! x**n into multiplications, and host and device must use the same order.
! The literal exponents below are those found by port/ipow_scan.py in the
! rewritten files (2, 3, 4, 8; 2.0**32 is exact).  Integer-variable exponents
! go through rp_pow (x**n unchanged) and are tested for n = -8..32.
! Pass: identical bits.
!
! Usage: t_ipow [log2_values]   (default 26)

PROGRAM t_ipow
   USE rm_testlib
   IMPLICIT NONE
   INTEGER, PARAMETER :: nlit = 4, nvar = 41
   REAL(r4), ALLOCATABLE :: a(:)
   REAL(r8), ALLOCATABLE :: a8(:)
   INTEGER(i4), ALLOCATABLE :: h4(:,:), d4(:,:)
   INTEGER(i8), ALLOCATABLE :: h8(:,:), d8(:,:)
   INTEGER(i8) :: n, k, seed, nb, total_bad
   INTEGER :: j, lg, nargs
   CHARACTER(LEN=16) :: arg

   lg = 26
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) lg
   END IF
   n = 2_i8**lg
   CALL require_device()
   ALLOCATE (a(n), a8(n), h4(nlit + nvar, n), d4(nlit + nvar, n), h8(nlit + nvar, n), d8(nlit + nvar, n))
   seed = 99_i8
   DO k = 1_i8, n
      ! values of moderate size so that x**32 stays finite for most inputs
      a(k)  = f4(IOR(IAND(splitmix64(seed), INT(Z'807FFFFF', i8)), INT(Z'3E000000', i8)) + &
                 IAND(splitmix64(seed), INT(Z'01800000', i8)))
      a8(k) = REAL(a(k), r8)*(1.0_r8 + 2.0_r8**(-30))
   END DO

!$omp target teams distribute parallel do map(to: a, a8) map(from: d4, d8)
   DO k = 1_i8, n
      CALL pw(a(k), a8(k), d4(:, k), d8(:, k))
   END DO
!$omp parallel do
   DO k = 1_i8, n
      CALL pw(a(k), a8(k), h4(:, k), h8(:, k))
   END DO

   total_bad = 0_i8
   DO j = 1, nlit + nvar
      nb = COUNT(h4(j, :) /= d4(j, :)) + COUNT(h8(j, :) /= d8(j, :))
      IF (nb /= 0_i8) THEN
         IF (j <= nlit) THEN
            PRINT '(a,i0,a,i0)', 'FAIL  T-IPOW literal exponent case ', j, ': ', nb
         ELSE
            PRINT '(a,i0,a,i0)', 'FAIL  T-IPOW variable exponent n=', j - nlit - 9, ': ', nb
         END IF
      END IF
      total_bad = total_bad + nb
   END DO
   CALL report('T-IPOW (literal 2,3,4,8 and variable -8..32; REAL(4) and REAL(8))', total_bad, 2_i8*n*(nlit + nvar))
   IF (total_bad /= 0_i8) STOP 1

CONTAINS

   SUBROUTINE pw(x, x8, r4o, r8o)
!$omp declare target
      REAL(r4), INTENT(IN) :: x
      REAL(r8), INTENT(IN) :: x8
      INTEGER(i4), INTENT(OUT) :: r4o(nlit + nvar)
      INTEGER(i8), INTENT(OUT) :: r8o(nlit + nvar)
      INTEGER :: m
      r4o(1) = bits4(x**2)
      r4o(2) = bits4(x**3)
      r4o(3) = bits4(x**4)
      r4o(4) = bits4(x**8)
      r8o(1) = bits8(x8**2)
      r8o(2) = bits8(x8**3)
      r8o(3) = bits8(x8**4)
      r8o(4) = bits8(x8**8)
      DO m = -8, 32
         r4o(nlit + m + 9) = bits4(rp_pow(x, m))
         r8o(nlit + m + 9) = bits8(rp_pow(x8, m))
      END DO
   END SUBROUTINE pw

END PROGRAM t_ipow
