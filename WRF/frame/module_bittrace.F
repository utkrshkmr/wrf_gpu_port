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
!                      also inside the step), 3 (fine: builds with
!                      -DWRF_TRACE_FINE only; see below)
!   WRF_BITTRACE_FROM  first itimestep to trace (default 0)
!   WRF_BITTRACE_TO    last itimestep to trace (default no limit)
!   WRF_BITTRACE_DOMAIN  trace only this domain id (default 0 = all)
!   WRF_BITTRACE_FIELDS  trace only these fields, comma-separated names as
!                        written in the trace (default: all)
!
! Output: bittrace.d0N.txt, one line per field:
!   itimestep rk_stage tag field hsum hpos      (hsum, hpos in hex)
! Compare two runs with port/bittrace_diff.py.
!
! Fine tracing (port/agent/DEBUGGING.md): builds made with build.sh --fine
! define WRF_TRACE_FINE, in the CPU-REF build as in the GPU build.  Then
! solve_em, first_rk_step_part1/2 and rk_tendency call a level-3 checkpoint
! after every routine they call (bt_checkpoint level 3 hashes more fields),
! and you can add checkpoints inside any routine, between two kernels:
!
!   #ifdef WRF_TRACE_FINE
!     CALL bt_fine3('advect_u:Y2', 'TENDENCY', tendency, 'X', &
!                   ids,ide, jds,jde, kds,kde, ims,ime, jms,jme, kms,kme, its,ite, jts,jte, kts,kte)
!   #endif
!
! (bt_fine2 for (ims:ime,jms:jme) arrays, bt_finef for fire-grid arrays).
! They hash the tile interior with global indices, so CPU-REF with many
! ranks and the GPU build with one rank give the same records.  Inside a
! routine that runs on the device (gpu_world_host is .FALSE. there) the
! array is first copied from the device.  Pass whole arrays or last-index
! slices of explicit-shape arrays (moist(:,:,:,n)).  The records carry the
! domain, step and RK stage of the last bt_context call (solve_em).

MODULE module_bittrace

   USE module_domain, ONLY : domain, get_ijk_from_grid, get_ijk_from_subgrid
   USE module_driver_constants, ONLY : max_domains
   USE module_wrf_error
#ifdef WRF_GPU
   USE module_gpu_route, ONLY : gpu_world_host
#endif

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: bt_on, bt_checkpoint, bt_field2, bt_field3, bt_fieldf, bt_flush
   PUBLIC :: bt_context, bt_fine_on, bt_fine2, bt_fine3, bt_finef

   INTEGER, PARAMETER :: i8 = SELECTED_INT_KIND(18)
   INTEGER(i8), PARAMETER :: MPRIME = 2147483647_i8
   INTEGER(i8), PARAMETER :: WMUL = 1103515245_i8, WADD = 12345_i8

   INTEGER, SAVE :: bt_level = -1
   INTEGER, SAVE :: bt_from = 0, bt_to = HUGE(0)
   INTEGER, SAVE :: bt_unit(max_domains) = -1
   LOGICAL, SAVE :: bt_opened(max_domains) = .FALSE.   ! NEWUNIT numbers are negative
   INTEGER, SAVE :: bt_dom = 0                          ! WRF_BITTRACE_DOMAIN
   CHARACTER(LEN=1024), SAVE :: bt_fields = ' '          ! WRF_BITTRACE_FIELDS, as ',A,B,'
   INTEGER, SAVE :: ctx_id = 0, ctx_step = 0, ctx_rk = 0 ! context of the fine checkpoints

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
      CALL get_environment_variable('WRF_BITTRACE_DOMAIN', v, status=st)
      IF (st == 0 .AND. LEN_TRIM(v) > 0) READ (v, *, iostat=st) bt_dom
      CALL get_environment_variable('WRF_BITTRACE_FIELDS', bt_fields, status=st)
      IF (st /= 0) bt_fields = ' '
      IF (LEN_TRIM(bt_fields) > 0) bt_fields = ','//TRIM(upcase(bt_fields))//','
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
      bt_on = bt_level >= level .AND. grid%itimestep >= bt_from .AND. grid%itimestep <= bt_to &
              .AND. (bt_dom == 0 .OR. grid%id == bt_dom)
   END FUNCTION bt_on

   ! context (domain, step, RK stage) of the fine checkpoints bt_fine*
   SUBROUTINE bt_context(grid, rk)
      TYPE(domain), INTENT(IN) :: grid
      INTEGER, INTENT(IN) :: rk
      ctx_id = grid%id
      ctx_step = grid%itimestep
      ctx_rk = rk
   END SUBROUTINE bt_context

   ! .TRUE. if fine checkpoints (level 3) are active in the current context
   LOGICAL FUNCTION bt_fine_on()
      IF (bt_level < 0) CALL bt_init()
      bt_fine_on = bt_level >= 3 .AND. ctx_id > 0 .AND. ctx_step >= bt_from .AND. ctx_step <= bt_to &
                   .AND. (bt_dom == 0 .OR. ctx_id == bt_dom)
   END FUNCTION bt_fine_on

   FUNCTION upcase(s) RESULT(u)
      CHARACTER(LEN=*), INTENT(IN) :: s
      CHARACTER(LEN=LEN(s)) :: u
      INTEGER :: i, c
      u = s
      DO i = 1, LEN(s)
         c = ICHAR(s(i:i))
         IF (c >= ICHAR('a') .AND. c <= ICHAR('z')) u(i:i) = CHAR(c - 32)
      END DO
   END FUNCTION upcase

   ! field filter WRF_BITTRACE_FIELDS
   LOGICAL FUNCTION want(name)
      CHARACTER(LEN=*), INTENT(IN) :: name
      want = LEN_TRIM(bt_fields) == 0
      IF (.NOT. want) want = INDEX(bt_fields, ','//TRIM(upcase(name))//',') > 0
   END FUNCTION want

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
      CALL emit_id(grid%id, grid%itimestep, tag, name, rk, hs, hp)
   END SUBROUTINE emit

   SUBROUTINE emit_id(id, step, tag, name, rk, hs, hp)
      INTEGER, INTENT(IN) :: id, step
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
      IF (.NOT. bt_opened(id)) THEN
         WRITE (fn, '(a,i2.2,a)') 'bittrace.d', id, '.txt'
         OPEN (NEWUNIT=bt_unit(id), FILE=TRIM(fn), STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
         IF (ios /= 0) CALL wrf_error_fatal('bittrace: cannot open '//TRIM(fn))
         bt_opened(id) = .TRUE.
      END IF
      WRITE (bt_unit(id), '(i9,1x,i1,1x,a,1x,a,1x,z16.16,1x,z16.16)') step, rk, &
         TRIM(tag), TRIM(name), glob(1), glob(2)
   END SUBROUTINE emit_id

   ! 3D atmospheric field; stag = 'X', 'Y', 'Z' or '-' (mass point)
   SUBROUTINE bt_field3(grid, tag, name, a, stag, rk)
      TYPE(domain), INTENT(IN) :: grid
      CHARACTER(LEN=*), INTENT(IN) :: tag, name, stag
      INTEGER, INTENT(IN) :: rk
      REAL, INTENT(IN) :: a(*)
      INTEGER :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, ips, ipe, jps, jpe, kps, kpe
      INTEGER :: i1, j1, k1
      INTEGER(i8) :: hs, hp
      IF (.NOT. want(name)) RETURN
      CALL get_ijk_from_grid(grid, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                             ips, ipe, jps, jpe, kps, kpe)
      i1 = MIN(ipe, ide - 1)
      j1 = MIN(jpe, jde - 1)
      k1 = MIN(kpe, kde - 1)
      IF (INDEX(stag, 'X') > 0) i1 = MIN(ipe, ide)
      IF (INDEX(stag, 'Y') > 0) j1 = MIN(jpe, jde)
      IF (INDEX(stag, 'Z') > 0) k1 = MIN(kpe, kde)
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
      IF (.NOT. want(name)) RETURN
      CALL get_ijk_from_grid(grid, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                             ips, ipe, jps, jpe, kps, kpe)
      i1 = MIN(ipe, ide - 1)
      j1 = MIN(jpe, jde - 1)
      IF (INDEX(stag, 'X') > 0) i1 = MIN(ipe, ide)
      IF (INDEX(stag, 'Y') > 0) j1 = MIN(jpe, jde)
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
      IF (.NOT. want(name)) RETURN
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
      IF (.NOT. want(name)) RETURN
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
      IF (level < 3 .OR. bt_level < 3) RETURN
      ! level 3 (fine tracing): intermediate dynamics and turbulence fields
      CALL bt_field3(grid, tag, 'U_1',     grid%u_1,     'X',  rk)
      CALL bt_field3(grid, tag, 'V_1',     grid%v_1,     'Y',  rk)
      CALL bt_field3(grid, tag, 'W_1',     grid%w_1,     'Z',  rk)
      CALL bt_field3(grid, tag, 'PH_1',    grid%ph_1,    'Z',  rk)
      CALL bt_field3(grid, tag, 'T_1',     grid%t_1,     '-',  rk)
      CALL bt_field2(grid, tag, 'MU_1',    grid%mu_1,    '-',  rk)
      CALL bt_field3(grid, tag, 'WW',      grid%ww,      'Z',  rk)
      CALL bt_field3(grid, tag, 'PHP',     grid%php,     '-',  rk)
      CALL bt_field3(grid, tag, 'ALT',     grid%alt,     '-',  rk)
      CALL bt_field3(grid, tag, 'RU_TEND', grid%ru_tend, 'X',  rk)
      CALL bt_field3(grid, tag, 'RV_TEND', grid%rv_tend, 'Y',  rk)
      CALL bt_field3(grid, tag, 'RU_M',    grid%ru_m,    'X',  rk)
      CALL bt_field3(grid, tag, 'RV_M',    grid%rv_m,    'Y',  rk)
      CALL bt_field3(grid, tag, 'WW_M',    grid%ww_m,    'Z',  rk)
      CALL bt_field3(grid, tag, 'U_SAVE',  grid%u_save,  'X',  rk)
      CALL bt_field3(grid, tag, 'V_SAVE',  grid%v_save,  'Y',  rk)
      CALL bt_field3(grid, tag, 'T_SAVE',  grid%t_save,  '-',  rk)
      CALL bt_field2(grid, tag, 'MUTS',    grid%muts,    '-',  rk)
      CALL bt_field2(grid, tag, 'MUDF',    grid%mudf,    '-',  rk)
      CALL bt_field2(grid, tag, 'MUU',     grid%muu,     'X',  rk)
      CALL bt_field2(grid, tag, 'MUV',     grid%muv,     'Y',  rk)
      CALL bt_field2(grid, tag, 'MUT',     grid%mut,     '-',  rk)
      IF (SIZE(grid%defor11) > 1) THEN
         CALL bt_field3(grid, tag, 'DEFOR11', grid%defor11, '-',  rk)
         CALL bt_field3(grid, tag, 'DEFOR22', grid%defor22, '-',  rk)
         CALL bt_field3(grid, tag, 'DEFOR33', grid%defor33, 'Z',  rk)
         CALL bt_field3(grid, tag, 'DEFOR12', grid%defor12, '-',  rk)
         CALL bt_field3(grid, tag, 'DEFOR13', grid%defor13, 'Z',  rk)
         CALL bt_field3(grid, tag, 'DEFOR23', grid%defor23, 'Z',  rk)
         CALL bt_field3(grid, tag, 'DIV',     grid%div,     '-',  rk)
      END IF
      IF (SIZE(grid%xkmh) > 1) THEN
         CALL bt_field3(grid, tag, 'XKMH', grid%xkmh, '-', rk)
         CALL bt_field3(grid, tag, 'XKMV', grid%xkmv, '-', rk)
         CALL bt_field3(grid, tag, 'XKHH', grid%xkhh, '-', rk)
         CALL bt_field3(grid, tag, 'XKHV', grid%xkhv, '-', rk)
      END IF
      IF (SIZE(grid%z_at_w) > 1) THEN
         CALL bt_field3(grid, tag, 'Z',      grid%z,      '-',  rk)
         CALL bt_field3(grid, tag, 'Z_AT_W', grid%z_at_w, 'Z',  rk)
         CALL bt_field3(grid, tag, 'ZX',     grid%zx,     'XZ', rk)
         CALL bt_field3(grid, tag, 'ZY',     grid%zy,     'YZ', rk)
         CALL bt_field3(grid, tag, 'RDZ',    grid%rdz,    'Z',  rk)
         CALL bt_field3(grid, tag, 'RDZW',   grid%rdzw,   'Z',  rk)
      END IF
   END SUBROUTINE bt_checkpoint

   ! ---- fine checkpoints inside routines (WRF_TRACE_FINE; header comment) ----

   ! (ims:ime, kms:kme, jms:jme) array over the tile interior; stag contains X, Y, Z or is '-'.
   ! No INTENT: when the routine runs on the device the host copy is refreshed first.
   SUBROUTINE bt_fine3(tag, name, a, stag, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                       its, ite, jts, jte, kts, kte)
      CHARACTER(LEN=*), INTENT(IN) :: tag, name, stag
      INTEGER, INTENT(IN) :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte
      REAL :: a(ims:ime, kms:kme, jms:jme)
      INTEGER :: i1, j1, k1
      INTEGER(i8) :: hs, hp
      IF (.NOT. bt_fine_on()) RETURN
      IF (.NOT. want(name)) RETURN
      i1 = MIN(ite, ide - 1)
      j1 = MIN(jte, jde - 1)
      k1 = MIN(kte, kde - 1)
      IF (INDEX(stag, 'X') > 0) i1 = MIN(ite, ide)
      IF (INDEX(stag, 'Y') > 0) j1 = MIN(jte, jde)
      IF (INDEX(stag, 'Z') > 0) k1 = MIN(kte, kde)
#ifdef WRF_GPU
      IF (.NOT. gpu_world_host) THEN
!$omp target update from(a)
      END IF
#endif
      CALL hash3(a, ims, ime, kms, kme, jms, jme, its, i1, kts, k1, jts, j1, ids, kds, jds, hs, hp)
      CALL emit_id(ctx_id, ctx_step, tag, name, ctx_rk, hs, hp)
   END SUBROUTINE bt_fine3

   ! (ims:ime, jms:jme) array over the tile interior; stag contains X, Y or is '-'
   SUBROUTINE bt_fine2(tag, name, a, stag, ids, ide, jds, jde, ims, ime, jms, jme, its, ite, jts, jte)
      CHARACTER(LEN=*), INTENT(IN) :: tag, name, stag
      INTEGER, INTENT(IN) :: ids, ide, jds, jde, ims, ime, jms, jme, its, ite, jts, jte
      REAL :: a(ims:ime, jms:jme)
      INTEGER :: i1, j1
      INTEGER(i8) :: hs, hp
      IF (.NOT. bt_fine_on()) RETURN
      IF (.NOT. want(name)) RETURN
      i1 = MIN(ite, ide - 1)
      j1 = MIN(jte, jde - 1)
      IF (INDEX(stag, 'X') > 0) i1 = MIN(ite, ide)
      IF (INDEX(stag, 'Y') > 0) j1 = MIN(jte, jde)
#ifdef WRF_GPU
      IF (.NOT. gpu_world_host) THEN
!$omp target update from(a)
      END IF
#endif
      CALL hash3(a, ims, ime, 1, 1, jms, jme, its, i1, 1, 1, jts, j1, ids, 1, jds, hs, hp)
      CALL emit_id(ctx_id, ctx_step, tag, name, ctx_rk, hs, hp)
   END SUBROUTINE bt_fine2

   ! fire-grid array (ifms:ifme, jfms:jfme) over the fire tile (as bt_fieldf: up to ifde, jfde)
   SUBROUTINE bt_finef(tag, name, a, ifds, ifde, jfds, jfde, ifms, ifme, jfms, jfme, ifts, ifte, jfts, jfte)
      CHARACTER(LEN=*), INTENT(IN) :: tag, name
      INTEGER, INTENT(IN) :: ifds, ifde, jfds, jfde, ifms, ifme, jfms, jfme, ifts, ifte, jfts, jfte
      REAL :: a(ifms:ifme, jfms:jfme)
      INTEGER(i8) :: hs, hp
      IF (.NOT. bt_fine_on()) RETURN
      IF (.NOT. want(name)) RETURN
#ifdef WRF_GPU
      IF (.NOT. gpu_world_host) THEN
!$omp target update from(a)
      END IF
#endif
      CALL hash3(a, ifms, ifme, 1, 1, jfms, jfme, ifts, MIN(ifte, ifde), 1, 1, jfts, MIN(jfte, jfde), &
                 ifds, 1, jfds, hs, hp)
      CALL emit_id(ctx_id, ctx_step, tag, name, ctx_rk, hs, hp)
   END SUBROUTINE bt_finef

   SUBROUTINE bt_flush(grid)
      TYPE(domain), INTENT(IN) :: grid
      IF (bt_level <= 0) RETURN
#ifndef NO_FLUSH_SUPPORT
      IF (bt_opened(grid%id)) FLUSH (bt_unit(grid%id))
#endif
   END SUBROUTINE bt_flush

END MODULE module_bittrace
