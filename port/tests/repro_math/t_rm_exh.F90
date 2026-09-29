! T-RM-EXH (plan.md P0.5): every REAL(4) bit pattern through every
! 1-argument rp_* function, host vs device.  Pass: 0 mismatches.
!
! Usage: t_rm_exh [first_fn last_fn [nchunks]]
!   function ids 1..12 (default all); nchunks limits the sweep to the first
!   nchunks blocks of 2**26 bit patterns (default 64 = all), for quick checks

PROGRAM t_rm_exh
   USE rm_testlib
   IMPLICIT NONE
   INTEGER(i8), PARAMETER :: chunk = 67108864_i8            ! 2**26
   INTEGER(i4), ALLOCATABLE :: hres(:), dres(:)
   INTEGER(i8) :: lo, k, nbad, first_bad, total_bad, lo_end
   INTEGER :: f, f0, f1, nargs, nch
   CHARACTER(LEN=16) :: arg
   REAL(r8) :: t0

   f0 = 1
   f1 = 12
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 2) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) f0
      CALL GET_COMMAND_ARGUMENT(2, arg)
      READ (arg, *) f1
   END IF
   nch = 64
   IF (nargs >= 3) THEN
      CALL GET_COMMAND_ARGUMENT(3, arg)
      READ (arg, *) nch
   END IF
   lo_end = INT(nch, i8)*chunk - 1_i8
   CALL require_device()
   ALLOCATE (hres(chunk), dres(chunk))
!$omp target enter data map(alloc: dres)
   total_bad = 0_i8
   DO f = f0, f1
      t0 = omp_get_wtime()
      nbad = 0_i8
      first_bad = -1_i8
      DO lo = 0_i8, lo_end, chunk
!$omp target teams distribute parallel do firstprivate(lo, f)
         DO k = 1_i8, chunk
            dres(k) = eval4(f, f4(lo + k - 1_i8), 0.0_r4)
         END DO
!$omp target update from(dres)
!$omp parallel do
         DO k = 1_i8, chunk
            hres(k) = eval4(f, f4(lo + k - 1_i8), 0.0_r4)
         END DO
         DO k = 1_i8, chunk
            IF (hres(k) /= dres(k)) THEN
               nbad = nbad + 1_i8
               IF (first_bad < 0_i8) first_bad = lo + k - 1_i8
            END IF
         END DO
      END DO
      CALL report('T-RM-EXH '//TRIM(fname(f)), nbad, lo_end + 1_i8)
      IF (first_bad >= 0_i8) PRINT '(a,z8.8)', '      first differing input bits: ', first_bad
      PRINT '(a,f8.1,a)', '      ', omp_get_wtime() - t0, ' s'
      total_bad = total_bad + nbad
   END DO
!$omp target exit data map(delete: dres)
   IF (total_bad /= 0_i8) STOP 1
END PROGRAM t_rm_exh
