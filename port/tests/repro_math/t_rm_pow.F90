! T-RM-POW (plan.md P0.5): rp_pow, rp_atan2 and rp_mod on REAL(4) pairs,
! host vs device.
!   (1) 2**30 random bit-pattern pairs for pow, atan2 and mod
!   (2) every REAL(4) x in [1e-3, 1e3] with the exponents used in WRF
! Pass: 0 mismatches.
!
! Usage: t_rm_pow [log2_random_pairs]   (default 30)

PROGRAM t_rm_pow
   USE rm_testlib
   IMPLICIT NONE
   INTEGER(i8), PARAMETER :: chunk = 16777216_i8            ! 2**24
   INTEGER, PARAMETER :: nexp = 48
   REAL(r4), PARAMETER :: wrf_exp(nexp) = (/ 0.25, 0.33, 0.33333333, 0.33333334, 0.46, 0.49, 0.5, &
      0.635, 1.31, 1.33, 1.5, 2.3333333, 0.2857143, 0.28571428, 1.4, 1.40285, 0.712, 0.1, 0.16,  &
      0.2, 0.75, 2.0, 2.5, 3.0, -0.3, -0.5, -1.0, -2.0, 0.19, 0.19026, 5.2559, 0.190284,          &
      0.1902659, 1.0e-4, 1.19, 0.9, 1.1, 0.65, 0.6, 0.4, 0.3, 0.8, 1.6, 2.1, 4.0, 5.0, 10.0,      &
      0.0625 /)
   REAL(r4), ALLOCATABLE :: a(:), b(:)
   INTEGER(i4), ALLOCATABLE :: hres(:), dres(:)
   INTEGER(i8) :: seed, k, npairs, nchunks, c, nbad, ntot, total_bad, xlo, xhi, x0
   INTEGER :: f, e, lg, nargs
   CHARACTER(LEN=16) :: arg

   lg = 30
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) lg
   END IF
   npairs = 2_i8**lg
   nchunks = MAX(1_i8, npairs/chunk)
   CALL require_device()
   ALLOCATE (a(chunk), b(chunk), hres(chunk), dres(chunk))
!$omp target enter data map(alloc: a, b, dres)
   total_bad = 0_i8

   ! (1) random pairs
   DO f = 13, 15
      seed = 12345_i8 + f
      nbad = 0_i8
      DO c = 1_i8, nchunks
         DO k = 1_i8, chunk
            a(k) = f4(splitmix64(seed))
            b(k) = f4(splitmix64(seed))
         END DO
         CALL run_chunk(f, nbad)
      END DO
      CALL report('T-RM-POW random '//TRIM(fname(f)), nbad, nchunks*chunk)
      total_bad = total_bad + nbad
   END DO

   ! (2) all floats in [1e-3, 1e3] with WRF exponents
   xlo = INT(TRANSFER(1.0e-3_r4, 0_i4), i8)
   xhi = INT(TRANSFER(1.0e3_r4, 0_i4), i8)
   nbad = 0_i8
   ntot = 0_i8
   DO e = 1, nexp
      DO x0 = xlo, xhi, chunk
         DO k = 1_i8, chunk
            a(k) = f4(MIN(x0 + k - 1_i8, xhi))
            b(k) = wrf_exp(e)
         END DO
         CALL run_chunk(14, nbad)
         ntot = ntot + chunk
      END DO
   END DO
   CALL report('T-RM-POW wrf-exponents', nbad, ntot)
   total_bad = total_bad + nbad

!$omp target exit data map(delete: a, b, dres)
   IF (total_bad /= 0_i8) STOP 1

CONTAINS

   SUBROUTINE run_chunk(fn, nb)
      INTEGER, INTENT(IN) :: fn
      INTEGER(i8), INTENT(INOUT) :: nb
      INTEGER(i8) :: j
!$omp target update to(a, b)
!$omp target teams distribute parallel do firstprivate(fn)
      DO j = 1_i8, chunk
         dres(j) = eval4(fn, a(j), b(j))
      END DO
!$omp target update from(dres)
!$omp parallel do
      DO j = 1_i8, chunk
         hres(j) = eval4(fn, a(j), b(j))
      END DO
      DO j = 1_i8, chunk
         IF (hres(j) /= dres(j)) nb = nb + 1_i8
      END DO
   END SUBROUTINE run_chunk

END PROGRAM t_rm_pow
