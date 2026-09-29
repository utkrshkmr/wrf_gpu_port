!WRF:DRIVER_LAYER:UTIL
!
! module_bittrace: bit-hash tracer for the GPU port (plan.md P0.7).
!
! At chosen points in the time step, each field is reduced to two 64-bit
! integers computed from the bit patterns of its values over the patch
! interior (the points the I/O layer writes, never halos):
!
!   hsum = sum of v                        v = bit pattern as unsigned 32-bit
!   hpos = sum of MOD(MOD(v,M)*w(g), M)    M = 2**31-1, w(g) = weight of the
!                                          point's global index g
!
! All arithmetic is exact integer arithmetic without overflow (values below
! 2**58 for 2**26 points), so the result does not depend on evaluation order,
! tiles, MPI decomposition, or CPU vs GPU.  hpos changes if values move
! between points.  With MPI the per-rank sums are added with MPI_Allreduce.
!
! Environment:
!   WRF_BITTRACE       0 (off, default), 1 (end of every step), 2 (debug:
!                      also inside the step)
!   WRF_BITTRACE_FROM  first itimestep to trace (default 0)
!   WRF_BITTRACE_TO    last itimestep to trace (default no limit)
!
! Output: bittrace.d0N.txt, one line per field:
!   itimestep rk_stage tag field hsum hpos      (hsum, hpos in hex)
! Compare two runs with port/bittrace_diff.py.

MODULE module_bittrace

   USE module_domain, ONLY : domain, get_ijk_from_grid, get_ijk_from_subgrid
   USE module_driver_constants, ONLY : max_domains
   USE module_wrf_error

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: bt_on, bt_checkpoint, bt_field2, bt_field3, bt_fieldf, bt_flush

   INTEGER, PARAMETER :: i8 = SELECTED_INT_KIND(18)
   INTEGER(i8), PARAMETER :: MPRIME = 2147483647_i8
   INTEGER(i8), PARAMETER :: WMUL = 1103515245_i8, WADD = 12345_i8

   INTEGER, SAVE :: bt_level = -1
   INTEGER, SAVE :: bt_from = 0, bt_to = HUGE(0)
   INTEGER, SAVE :: bt_unit(max_domains) = -1

CONTAINS

   SUBROUTINE bt_init()
      CHARACTER(LEN=32) :: v
      INTEGER :: st
      bt_level = 0
      CALL get_environment_variable('WRF_BITTRACE', v, status=st)
      IF (st == 0 .AND. LEN_TRIM(v) > 0) READ (v, *, iostat=st) bt_level
      CALL get_environment_variable('WRF_BITTRACE_FROM', v, status=st)
      IF (st == 0 .AND. LEN_TRIM(v) > 0) READ (v, *, iostat=st) bt_from
      CALL get_environment_variable('WRF_BITTRACE_TO', v, status=st)
      IF (st == 0 .AND. LEN_TRIM(v) > 0) READ (v, *, iostat=st) bt_to
      IF (bt_level > 0) THEN
         WRITE (wrf_err_message, '(a,i2,a,i10,a,i10)') 'bittrace: level ', bt_level, &
            ' itimestep ', bt_from, ' to ', bt_to
         CALL wrf_message(TRIM(wrf_err_message))
      END IF
   END SUBROUTINE bt_init

   ! .TRUE. if tracing at this level is active for this domain and step
   LOGICAL FUNCTION bt_on(grid, level)
      TYPE(domain), INTENT(IN) :: grid
      INTEGER, INTENT(IN) :: level
      IF (bt_level < 0) CALL bt_init()
      bt_on = bt_level >= level .AND. grid%itimestep >= bt_from .AND. grid%itimestep <= bt_to
   END FUNCTION bt_on

   ! weight of global point index g, in 1 .. MPRIME-1
   PURE INTEGER(i8) FUNCTION wgt(g)
      INTEGER(i8), INTENT(IN) :: g
      wgt = 1_i8 + MOD(MOD(g, MPRIME)*WMUL + WADD, MPRIME - 1_i8)
   END FUNCTION wgt

   PURE INTEGER(i8) FUNCTION ubits(x)
      REAL, INTENT(IN) :: x
      INTEGER :: b
      b = TRANSFER(x, b)
      ubits = IAND(INT(b, i8), 4294967295_i8)
   END FUNCTION ubits

   ! hash a(i0:i1, k0:k1, j0:j1) of an array with bounds (ims:ime, kms:kme, jms:jme)
   SUBROUTINE hash3(a, ims, ime, kms, kme, jms, jme, i0, i1, k0, k1, j0, j1, ioff, koff, joff, hs, hp)
      INTEGER, INTENT(IN) :: ims, ime, kms, kme, jms, jme, i0, i1, k0, k1, j0, j1, ioff, koff, joff
      REAL, INTENT(IN) :: a(ims:ime, kms:kme, jms:jme)
      INTEGER(i8), INTENT(OUT) :: hs, hp
      INTEGER(i8) :: v, g
      INTEGER :: i, k, j
      hs = 0_i8
      hp = 0_i8
      DO j = j0, j1
         DO k = k0, k1
            DO i = i0, i1
               v  = ubits(a(i, k, j))
               g  = INT(i - ioff, i8) + 8192_i8*(INT(k - koff, i8) + 1024_i8*INT(j - joff, i8))
               hs = hs + v
               hp = hp + MOD(MOD(v, MPRIME)*wgt(g), MPRIME)
            END DO
         END DO
      END DO
   END SUBROUTINE hash3

   SUBROUTINE emit(grid, tag, name, rk, hs, hp)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag, name
      INTEGER, INTENT(IN) :: rk
      INTEGER(i8), INTENT(IN) :: hs, hp
      INTEGER(i8) :: loc(2), glob(2)
      CHARACTER(LEN=32) :: fn
      INTEGER :: ios
      LOGICAL, EXTERNAL :: wrf_dm_on_monitor
#if defined(DM_PARALLEL) && !defined(STUBMPI)
      INTEGER :: comm, ierr
      INCLUDE 'mpif.h'
      loc(1) = hs
      loc(2) = hp
      CALL wrf_get_dm_communicator(comm)
      CALL MPI_Allreduce(loc, glob, 2, MPI_INTEGER8, MPI_SUM, comm, ierr)
#else
      loc(1) = hs
      loc(2) = hp
      glob = loc
#endif
      IF (.NOT. wrf_dm_on_monitor()) RETURN
      IF (bt_unit(grid%id) < 0) THEN
         WRITE (fn, '(a,i2.2,a)') 'bittrace.d', grid%id, '.txt'
         OPEN (NEWUNIT=bt_unit(grid%id), FILE=TRIM(fn), STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
         IF (ios /= 0) CALL wrf_error_fatal('bittrace: cannot open '//TRIM(fn))
      END IF
      WRITE (bt_unit(grid%id), '(i9,1x,i1,1x,a,1x,a,1x,z16.16,1x,z16.16)') grid%itimestep, rk, &
         TRIM(tag), TRIM(name), glob(1), glob(2)
   END SUBROUTINE emit

   ! 3D atmospheric field; stag = 'X', 'Y', 'Z' or '-' (mass point)
   SUBROUTINE bt_field3(grid, tag, name, a, stag, rk)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag, name, stag
      INTEGER, INTENT(IN) :: rk
      REAL, INTENT(IN) :: a(*)
      INTEGER :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, ips, ipe, jps, jpe, kps, kpe
      INTEGER :: i1, j1, k1
      INTEGER(i8) :: hs, hp
      CALL get_ijk_from_grid(grid, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                             ips, ipe, jps, jpe, kps, kpe)
      i1 = MIN(ipe, ide - 1)
      j1 = MIN(jpe, jde - 1)
      k1 = MIN(kpe, kde - 1)
      IF (stag == 'X') i1 = MIN(ipe, ide)
      IF (stag == 'Y') j1 = MIN(jpe, jde)
      IF (stag == 'Z') k1 = MIN(kpe, kde)
      CALL hash3(a, ims, ime, kms, kme, jms, jme, ips, i1, kps, k1, jps, j1, ids, kds, jds, hs, hp)
      CALL emit(grid, tag, name, rk, hs, hp)
   END SUBROUTINE bt_field3

   ! 2D atmospheric field (ims:ime, jms:jme); stag as for bt_field3 ('Z' ignored)
   SUBROUTINE bt_field2(grid, tag, name, a, stag, rk)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag, name, stag
      INTEGER, INTENT(IN) :: rk
      REAL, INTENT(IN) :: a(*)
      INTEGER :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, ips, ipe, jps, jpe, kps, kpe
      INTEGER :: i1, j1
      INTEGER(i8) :: hs, hp
      CALL get_ijk_from_grid(grid, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                             ips, ipe, jps, jpe, kps, kpe)
      i1 = MIN(ipe, ide - 1)
      j1 = MIN(jpe, jde - 1)
      IF (stag == 'X') i1 = MIN(ipe, ide)
      IF (stag == 'Y') j1 = MIN(jpe, jde)
      CALL hash3(a, ims, ime, 1, 1, jms, jme, ips, i1, 1, 1, jps, j1, ids, 1, jds, hs, hp)
      CALL emit(grid, tag, name, rk, hs, hp)
   END SUBROUTINE bt_field2

   ! 3D field with a non-standard vertical extent (soil layers): a(ims:ime, k0:k1, jms:jme)
   SUBROUTINE bt_fieldk(grid, tag, name, a, k0, k1, rk)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag, name
      INTEGER, INTENT(IN) :: k0, k1, rk
      REAL, INTENT(IN) :: a(*)
      INTEGER :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, ips, ipe, jps, jpe, kps, kpe
      INTEGER(i8) :: hs, hp
      CALL get_ijk_from_grid(grid, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                             ips, ipe, jps, jpe, kps, kpe)
      CALL hash3(a, ims, ime, k0, k1, jms, jme, ips, MIN(ipe, ide - 1), k0, k1, jps, MIN(jpe, jde - 1), &
                 ids, k0, jds, hs, hp)
      CALL emit(grid, tag, name, rk, hs, hp)
   END SUBROUTINE bt_fieldk

   ! fire-grid field (ifms:ifme, jfms:jfme), hashed over the whole refined
   ! patch (the extent written to the history file)
   SUBROUTINE bt_fieldf(grid, tag, name, a, rk)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag, name
      INTEGER, INTENT(IN) :: rk
      REAL, INTENT(IN) :: a(*)
      INTEGER :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, ips, ipe, jps, jpe, kps, kpe
      INTEGER(i8) :: hs, hp
      CALL get_ijk_from_subgrid(grid, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                                ips, ipe, jps, jpe, kps, kpe)
      CALL hash3(a, ims, ime, 1, 1, jms, jme, ips, MIN(ipe, ide), 1, 1, jps, MIN(jpe, jde), &
                 ids, 1, jds, hs, hp)
      CALL emit(grid, tag, name, rk, hs, hp)
   END SUBROUTINE bt_fieldf

   ! Standard field sets.  level 1: prognostic state and fire state;
   ! level 2 adds physics tendencies and surface fields.
   SUBROUTINE bt_checkpoint(grid, tag, level, rk)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag
      INTEGER, INTENT(IN) :: level, rk
      INTEGER :: m
      CHARACTER(LEN=16) :: nm

      IF (.NOT. bt_on(grid, level)) RETURN
      CALL bt_field3(grid, tag, 'U_2',  grid%u_2,  'X', rk)
      CALL bt_field3(grid, tag, 'V_2',  grid%v_2,  'Y', rk)
      CALL bt_field3(grid, tag, 'W_2',  grid%w_2,  'Z', rk)
      CALL bt_field3(grid, tag, 'PH_2', grid%ph_2, 'Z', rk)
      CALL bt_field3(grid, tag, 'T_2',  grid%t_2,  '-', rk)
      CALL bt_field3(grid, tag, 'P',    grid%p,    '-', rk)
      CALL bt_field3(grid, tag, 'AL',   grid%al,   '-', rk)
      CALL bt_field2(grid, tag, 'MU_2', grid%mu_2, '-', rk)
      DO m = 2, SIZE(grid%moist, 4)
         WRITE (nm, '(a,i2.2)') 'MOIST', m
         CALL bt_field3(grid, tag, TRIM(nm), grid%moist(:, :, :, m), '-', rk)
      END DO
      IF (SIZE(grid%tke_2) > 1) CALL bt_field3(grid, tag, 'TKE_2', grid%tke_2, '-', rk)
      IF (SIZE(grid%lfn) > 1) THEN
         CALL bt_fieldf(grid, tag, 'LFN',       grid%lfn,       rk)
         CALL bt_fieldf(grid, tag, 'TIGN_G',    grid%tign_g,    rk)
         CALL bt_fieldf(grid, tag, 'FIRE_AREA', grid%fire_area, rk)
         CALL bt_fieldf(grid, tag, 'FUEL_FRAC', grid%fuel_frac, rk)
         CALL bt_fieldf(grid, tag, 'FGRNHFX',   grid%fgrnhfx,   rk)
         CALL bt_fieldf(grid, tag, 'FGRNQFX',   grid%fgrnqfx,   rk)
      END IF
      IF (level < 2 .OR. bt_level < 2) RETURN
      IF (SIZE(grid%rthraten) > 1) CALL bt_field3(grid, tag, 'RTHRATEN', grid%rthraten, '-', rk)
      IF (SIZE(grid%rthblten) > 1) CALL bt_field3(grid, tag, 'RTHBLTEN', grid%rthblten, '-', rk)
      IF (SIZE(grid%rublten) > 1)  CALL bt_field3(grid, tag, 'RUBLTEN',  grid%rublten,  '-', rk)
      IF (SIZE(grid%rvblten) > 1)  CALL bt_field3(grid, tag, 'RVBLTEN',  grid%rvblten,  '-', rk)
      IF (SIZE(grid%rqvblten) > 1) CALL bt_field3(grid, tag, 'RQVBLTEN', grid%rqvblten, '-', rk)
      IF (SIZE(grid%rthfrten) > 1) CALL bt_field3(grid, tag, 'RTHFRTEN', grid%rthfrten, '-', rk)
      IF (SIZE(grid%rqvfrten) > 1) CALL bt_field3(grid, tag, 'RQVFRTEN', grid%rqvfrten, '-', rk)
      CALL bt_field3(grid, tag, 'H_DIABATIC', grid%h_diabatic, '-', rk)
      CALL bt_field2(grid, tag, 'TSK',    grid%tsk,    '-', rk)
      CALL bt_field2(grid, tag, 'HFX',    grid%hfx,    '-', rk)
      CALL bt_field2(grid, tag, 'QFX',    grid%qfx,    '-', rk)
      CALL bt_field2(grid, tag, 'UST',    grid%ust,    '-', rk)
      CALL bt_field2(grid, tag, 'PBLH',   grid%pblh,   '-', rk)
      CALL bt_field2(grid, tag, 'GLW',    grid%glw,    '-', rk)
      CALL bt_field2(grid, tag, 'GSW',    grid%gsw,    '-', rk)
      CALL bt_field2(grid, tag, 'RAINNC', grid%rainnc, '-', rk)
      IF (SIZE(grid%tslb) > 1) CALL bt_fieldk(grid, tag, 'TSLB', grid%tslb, &
                                              LBOUND(grid%tslb, 2), UBOUND(grid%tslb, 2), rk)
      IF (SIZE(grid%smois) > 1) CALL bt_fieldk(grid, tag, 'SMOIS', grid%smois, &
                                               LBOUND(grid%smois, 2), UBOUND(grid%smois, 2), rk)
   END SUBROUTINE bt_checkpoint

   SUBROUTINE bt_flush(grid)
      TYPE(domain), INTENT(IN) :: grid
      IF (bt_level <= 0) RETURN
#ifndef NO_FLUSH_SUPPORT
      IF (bt_unit(grid%id) >= 0) FLUSH (bt_unit(grid%id))
#endif
   END SUBROUTINE bt_flush

END MODULE module_bittrace
