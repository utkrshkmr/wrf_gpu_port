! T-RM-D (plan.md P0.5): every rp_* function on REAL(8) arguments, host vs
! device: random bit patterns, random values in each function's useful range,
! and all pairs of special values.  Pass: 0 mismatches.
!
! Usage: t_rm_d [log2_values_per_function]   (default 30, i.e. about 10**9)

PROGRAM t_rm_d
   USE rm_testlib
   IMPLICIT NONE
   INTEGER(i8), PARAMETER :: chunk = 16777216_i8            ! 2**24
   INTEGER, PARAMETER :: nsp = 26
   REAL(r8) :: sp(nsp)
   REAL(r8), ALLOCATABLE :: a(:), b(:)
   INTEGER(i8), ALLOCATABLE :: hres(:), dres(:)
   INTEGER(i8) :: seed, k, nchunks, c, nbad, total_bad, u
   INTEGER :: f, lg, nargs, i, j
   CHARACTER(LEN=16) :: arg
   REAL(r8) :: zero

   lg = 30
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) lg
   END IF
   nchunks = MAX(1_i8, 2_i8**lg/chunk)
   CALL require_device()
   zero = 0.0_r8
   sp = (/ 0.0_r8, -zero, 1.0_r8, -1.0_r8, 0.5_r8, -0.5_r8, 2.0_r8, -2.0_r8, 1.5707963267948966_r8,   &
           3.141592653589793_r8, 709.782712893384_r8, -745.1332191019411_r8, 22.0_r8, 1.0e22_r8,       &
           1.0e300_r8, -1.0e300_r8, 5.0e-324_r8, 2.2250738585072014e-308_r8, 1.7976931348623157e308_r8, &
           0.9999999999999999_r8, 1.0000000000000002_r8, 710.4758600739439_r8, 1.0e-20_r8, 3.0_r8,     &
           TRANSFER(9218868437227405312_i8, 1.0_r8), TRANSFER(-4503599627370496_i8, 1.0_r8) /)
   ALLOCATE (a(chunk), b(chunk), hres(chunk), dres(chunk))
!$omp target enter data map(alloc: a, b, dres)
   total_bad = 0_i8
   DO f = 1, 15
      seed = 777_i8 + f
      nbad = 0_i8
      DO c = 1_i8, nchunks
         DO k = 1_i8, chunk
            u = splitmix64(seed)
            SELECT CASE (MOD(c, 3_i8))
            CASE (0_i8)
               ! random bit patterns
               a(k) = TRANSFER(u, 1.0_r8)
               b(k) = TRANSFER(splitmix64(seed), 1.0_r8)
            CASE (1_i8)
               ! moderate values
               a(k) = (REAL(ISHFT(u, -11), r8)*2.0_r8**(-53) - 0.5_r8)*40.0_r8
               b(k) = (REAL(ISHFT(splitmix64(seed), -11), r8)*2.0_r8**(-53) - 0.5_r8)*8.0_r8
            CASE DEFAULT
               ! unit interval and wide exponent range
               a(k) = REAL(ISHFT(u, -11), r8)*2.0_r8**(-53)*2.0_r8 - 1.0_r8
               b(k) = REAL(ISHFT(splitmix64(seed), -11), r8)*2.0_r8**(-53)*1400.0_r8 - 700.0_r8
            END SELECT
         END DO
         IF (c == 1_i8) THEN
            k = 0_i8
            DO i = 1, nsp
               DO j = 1, nsp
                  k = k + 1_i8
                  a(k) = sp(i)
                  b(k) = sp(j)
               END DO
            END DO
         END IF
!$omp target update to(a, b)
!$omp target teams distribute parallel do firstprivate(f)
         DO k = 1_i8, chunk
            dres(k) = eval8(f, a(k), b(k))
         END DO
!$omp target update from(dres)
!$omp parallel do
         DO k = 1_i8, chunk
            hres(k) = eval8(f, a(k), b(k))
         END DO
         DO k = 1_i8, chunk
            IF (hres(k) /= dres(k)) nbad = nbad + 1_i8
         END DO
      END DO
      CALL report('T-RM-D '//TRIM(fname(f)), nbad, nchunks*chunk)
      total_bad = total_bad + nbad
   END DO
!$omp target exit data map(delete: a, b, dres)
   IF (total_bad /= 0_i8) STOP 1
END PROGRAM t_rm_d
