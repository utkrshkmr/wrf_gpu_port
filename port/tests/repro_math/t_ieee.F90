! T-SIGNZERO, T-MINMAX, T-SUBNORM (plan.md P0.5): basic operations and
! sign/min/max intrinsics, host vs device, REAL(4) and REAL(8).
!
!   special operands : +-0, +-min subnormal, +-max subnormal, +-min normal,
!                      +-1, +-max, +-Inf, NaN, ordinary values; all ordered
!                      pairs through SIGN, MAX, MIN, ABS, + - * / SQRT and
!                      REAL(8)->REAL(4) conversion
!   random operands  : subnormal pairs, and 2**N normal pairs for / and SQRT
!                      (a device divide or square root that is not correctly
!                      rounded shows up here)
! Pass: identical bits (NaN results compared as "both NaN"), and no subnormal
! flushed to zero.
!
! Usage: t_ieee [log2_random_pairs]   (default 30)

PROGRAM t_ieee
   USE rm_testlib
   IMPLICIT NONE
   INTEGER, PARAMETER :: nops = 12
   INTEGER, PARAMETER :: ns4 = 24
   INTEGER(i8), PARAMETER :: chunk = 16777216_i8
   REAL(r4) :: s4(ns4)
   REAL(r4), ALLOCATABLE :: a(:), b(:)
   INTEGER(i4), ALLOCATABLE :: hres(:,:), dres(:,:)
   REAL(r8), ALLOCATABLE :: a8(:), b8(:)
   INTEGER(i8), ALLOCATABLE :: hres8(:,:), dres8(:,:)
   INTEGER(i8) :: n, k, seed, nbad(nops), total_bad, nchunks, c
   INTEGER :: i, j, op, lg, nargs
   CHARACTER(LEN=16) :: arg
   CHARACTER(LEN=10), PARAMETER :: opname(nops) = (/ 'SIGN(1,x) ', 'SIGN(a,b) ', 'MAX(a,b)  ', &
      'MIN(a,b)  ', 'ABS(a)    ', 'a+b       ', 'a-b       ', 'a*b       ', 'a/b       ',       &
      'SQRT(a)   ', 'REAL8->4  ', 'MAX(b,a)  ' /)
   REAL(r4) :: zero

   lg = 30
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) lg
   END IF
   nchunks = MAX(1_i8, 2_i8**lg/chunk)
   CALL require_device()
   total_bad = 0_i8
   zero = 0.0_r4
   s4 = (/ 0.0_r4, -zero, f4(1_i8), -f4(1_i8), f4(8388607_i8), -f4(8388607_i8), TINY(1.0_r4), &
           -TINY(1.0_r4), 1.0_r4, -1.0_r4, HUGE(1.0_r4), -HUGE(1.0_r4), f4(2139095040_i8),      &
           f4(4286578688_i8), f4(2143289344_i8), 0.5_r4, -0.5_r4, 3.0_r4, 1.0e-30_r4, 1.0e30_r4,   &
           2.0_r4, -7.25_r4, 1.1754942e-38_r4, 5.8774718e-39_r4 /)

   ! --- special operand pairs, REAL(4)
   n = INT(ns4*ns4, i8)
   ALLOCATE (a(n), b(n), hres(nops, n), dres(nops, n))
   k = 0_i8
   DO i = 1, ns4
      DO j = 1, ns4
         k = k + 1_i8
         a(k) = s4(i)
         b(k) = s4(j)
      END DO
   END DO
   CALL run4(n)
   CALL compare4(n, 'specials REAL(4)')
   DEALLOCATE (a, b, hres, dres)

   ! --- random operands: subnormal pairs, then random normal pairs
   ALLOCATE (a(chunk), b(chunk), hres(nops, chunk), dres(nops, chunk))
   seed = 4242_i8
   nbad = 0_i8
   DO c = 1_i8, nchunks
      DO k = 1_i8, chunk
         IF (c == 1_i8) THEN
            a(k) = f4(IAND(splitmix64(seed), 8388607_i8) + IAND(splitmix64(seed), 1_i8)*2147483648_i8)
            b(k) = f4(IAND(splitmix64(seed), 8388607_i8) + IAND(splitmix64(seed), 1_i8)*2147483648_i8)
         ELSE
            a(k) = f4(splitmix64(seed))
            b(k) = f4(splitmix64(seed))
         END IF
      END DO
      CALL run4(chunk)
      CALL count4(chunk)
   END DO
   DO op = 1, nops
      CALL report('T-IEEE random REAL(4) '//TRIM(opname(op)), nbad(op), nchunks*chunk)
      total_bad = total_bad + nbad(op)
   END DO
   DEALLOCATE (a, b, hres, dres)

   ! --- random REAL(8) pairs
   ALLOCATE (a8(chunk), b8(chunk), hres8(nops, chunk), dres8(nops, chunk))
   nbad = 0_i8
   DO c = 1_i8, MAX(1_i8, nchunks/4_i8)
      DO k = 1_i8, chunk
         a8(k) = TRANSFER(splitmix64(seed), 1.0_r8)
         b8(k) = TRANSFER(splitmix64(seed), 1.0_r8)
      END DO
      IF (c == 1_i8) THEN
         DO k = 1_i8, INT(ns4, i8)
            a8(k) = REAL(s4(k), r8)
            b8(k) = 5.0e-324_r8
         END DO
      END IF
      CALL run8(chunk)
   END DO
   DO op = 1, nops
      CALL report('T-IEEE random REAL(8) '//TRIM(opname(op)), nbad(op), MAX(1_i8, nchunks/4_i8)*chunk)
      total_bad = total_bad + nbad(op)
   END DO

   IF (total_bad /= 0_i8) STOP 1

CONTAINS

   SUBROUTINE run4(m)
      INTEGER(i8), INTENT(IN) :: m
      INTEGER(i8) :: q
!$omp target teams distribute parallel do map(to: a(1:m), b(1:m)) map(from: dres(:, 1:m))
      DO q = 1_i8, m
         CALL ops4(a(q), b(q), dres(:, q))
      END DO
!$omp parallel do
      DO q = 1_i8, m
         CALL ops4(a(q), b(q), hres(:, q))
      END DO
   END SUBROUTINE run4

   SUBROUTINE ops4(x, y, r)
!$omp declare target
      REAL(r4), INTENT(IN) :: x, y
      INTEGER(i4), INTENT(OUT) :: r(nops)
      r(1)  = bits4(SIGN(1.0_r4, x))
      r(2)  = bits4(SIGN(x, y))
      r(3)  = bits4(MAX(x, y))
      r(4)  = bits4(MIN(x, y))
      r(5)  = bits4(ABS(x))
      r(6)  = bits4(x + y)
      r(7)  = bits4(x - y)
      r(8)  = bits4(x*y)
      r(9)  = bits4(x/y)
      r(10) = bits4(SQRT(ABS(x)))
      r(11) = bits4(REAL(REAL(x, r8)*REAL(y, r8)*1.0000001_r8, r4))
      r(12) = bits4(MAX(y, x))
   END SUBROUTINE ops4

   ! NaN results compare equal whatever their payload
   LOGICAL FUNCTION same4(p, q)
      INTEGER(i4), INTENT(IN) :: p, q
      REAL(r4) :: x, y
      x = TRANSFER(p, x)
      y = TRANSFER(q, y)
      same4 = (p == q) .OR. ((x /= x) .AND. (y /= y))
   END FUNCTION same4

   SUBROUTINE compare4(m, label)
      INTEGER(i8), INTENT(IN) :: m
      CHARACTER(LEN=*), INTENT(IN) :: label
      INTEGER(i8) :: q, nb
      nb = 0_i8
      DO q = 1_i8, m
         DO op = 1, nops
            IF (.NOT. same4(hres(op, q), dres(op, q))) THEN
               nb = nb + 1_i8
               PRINT '(a,a,a,z8.8,a,z8.8,a,z8.8,a,z8.8)', '      ', opname(op), ' a=', bits4(a(q)), &
                  ' b=', bits4(b(q)), ' host=', hres(op, q), ' device=', dres(op, q)
            END IF
         END DO
      END DO
      CALL report('T-SIGNZERO/T-MINMAX/T-SUBNORM '//label, nb, m*nops)
      total_bad = total_bad + nb
   END SUBROUTINE compare4

   SUBROUTINE count4(m)
      INTEGER(i8), INTENT(IN) :: m
      INTEGER(i8) :: q
      DO q = 1_i8, m
         DO op = 1, nops
            IF (.NOT. same4(hres(op, q), dres(op, q))) nbad(op) = nbad(op) + 1_i8
         END DO
      END DO
   END SUBROUTINE count4

   SUBROUTINE run8(m)
      INTEGER(i8), INTENT(IN) :: m
      INTEGER(i8) :: q
      REAL(r8) :: x, y
!$omp target teams distribute parallel do map(to: a8(1:m), b8(1:m)) map(from: dres8(:, 1:m))
      DO q = 1_i8, m
         CALL ops8(a8(q), b8(q), dres8(:, q))
      END DO
!$omp parallel do
      DO q = 1_i8, m
         CALL ops8(a8(q), b8(q), hres8(:, q))
      END DO
      DO q = 1_i8, m
         DO op = 1, nops
            x = TRANSFER(hres8(op, q), 1.0_r8)
            y = TRANSFER(dres8(op, q), 1.0_r8)
            IF (hres8(op, q) /= dres8(op, q) .AND. .NOT. ((x /= x) .AND. (y /= y))) nbad(op) = nbad(op) + 1_i8
         END DO
      END DO
   END SUBROUTINE run8

   SUBROUTINE ops8(x, y, r)
!$omp declare target
      REAL(r8), INTENT(IN) :: x, y
      INTEGER(i8), INTENT(OUT) :: r(nops)
      r(1)  = bits8(SIGN(1.0_r8, x))
      r(2)  = bits8(SIGN(x, y))
      r(3)  = bits8(MAX(x, y))
      r(4)  = bits8(MIN(x, y))
      r(5)  = bits8(ABS(x))
      r(6)  = bits8(x + y)
      r(7)  = bits8(x - y)
      r(8)  = bits8(x*y)
      r(9)  = bits8(x/y)
      r(10) = bits8(SQRT(ABS(x)))
      r(11) = INT(bits4(REAL(x, r4)), i8)
      r(12) = bits8(MAX(y, x))
   END SUBROUTINE ops8

END PROGRAM t_ieee
