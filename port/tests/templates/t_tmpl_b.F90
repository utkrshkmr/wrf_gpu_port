! Template B (plan.md 7.0/7.2, kernels K-ADVU-Y1 / K-ADVU-Y2): a j-loop that
! carries a rolling buffer between iterations becomes two kernels.
!
! Original (advect_u, 5th-order y-flux, verbatim below): for j = j_start ..
! j_end+1 the face flux of row j is computed into fqy(:,:,jp1), and for j >
! j_start the tendency of row j-1 is updated from fqy(jp1) - fqy(jp0); then
! jp1 and jp0 swap.  The flux of each face is computed once, with the branch
! (full stencil, 2nd order, 3rd order) chosen by j.
!
! GPU version (advect_u_yflux_gpu):
!   Y1: every face flux into the 3D array fqy3(i,k,j) (a pool/work array),
!       j = j_start .. j_end+1, the same branch for the same j, the same
!       expressions (vel is a private scalar);
!   Y2: tendency(i,k,j-1) = tendency(i,k,j-1) - mrdy*(fqy3(i,k,j)-fqy3(i,k,j-1))
!       for j = j_start+1 .. j_end+1 (the source's "IF (j > j_start)"), mrdy
!       private.  fqy3(j) is the source's fqy(jp1), fqy3(j-1) its fqy(jp0).
! The polar branches are not ported (gpu_check_config rejects polar).
!
! The test compares tendency bit for bit on random fields for several tile
! positions (single tile, south edge, north edge, interior), on the host and
! in target regions.  Usage: t_tmpl_b [nrep]; ALLOW_HOST=1 for host-only.
!
! Statement functions (flux3..flux6) are used inside the kernel, as in WRF.  If
! the compiler rejects them in device code, compile with -DTMPL_NO_STMTFN (the
! Makefile variable TMPL_B_FLAGS; port/tests/run_ref_tests.sh does this
! automatically): each statement function is then a module function with the
! identical expression and !$omp declare target, and the variable it took from
! its host scope (time_step) becomes an argument.  That is the conversion
! CODING_STANDARD.md prescribes for WRF when probe F-STMTFN fails.

#ifdef TMPL_NO_STMTFN
#  define STMTFN_TS , time_step
#else
#  define STMTFN_TS
#endif

MODULE tb_mod
   IMPLICIT NONE
   TYPE grid_config_rec_type
      LOGICAL :: periodic_x = .false., periodic_y = .false.
      LOGICAL :: symmetric_xs = .false., symmetric_xe = .false., symmetric_ys = .false., symmetric_ye = .false.
      LOGICAL :: open_xs = .false., open_xe = .false., open_ys = .false., open_ye = .false.
      LOGICAL :: specified = .true., nested = .false., polar = .false.
   END TYPE grid_config_rec_type
CONTAINS

SUBROUTINE advect_u_yflux_orig(u, rv, msfux, tendency, rdy, time_step, config_flags, &
                               ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                               its, ite, jts, jte, kts, kte)
   TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
   INTEGER, INTENT(IN) :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: u, rv
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: tendency
   REAL, DIMENSION(ims:ime, jms:jme), INTENT(IN) :: msfux
   REAL, INTENT(IN) :: rdy
   INTEGER, INTENT(IN) :: time_step
   INTEGER :: i, j, k, ktf
   INTEGER :: i_start, i_end, j_start, j_end, j_start_f, j_end_f
   INTEGER :: jp1, jp0, jtmp
   REAL :: mrdy
   REAL, DIMENSION(its:ite, kts:kte, 2) :: fqy
   LOGICAL :: degrade_xs, degrade_ys, degrade_xe, degrade_ye, specified
   REAL    :: flux3, flux4, flux5, flux6
   REAL    :: q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua, vel

! BEGIN VERBATIM WRF/dyn_em/module_advect_em.F
   flux4(q_im2, q_im1, q_i, q_ip1, ua) =                         &
          ( 7.*(q_i + q_im1) - (q_ip1 + q_im2) )/12.0

   flux3(q_im2, q_im1, q_i, q_ip1, ua) =                         &
            flux4(q_im2, q_im1, q_i, q_ip1, ua) +                &
            sign(1,time_step)*sign(1.,ua)*((q_ip1 - q_im2)-3.*(q_i-q_im1))/12.0

   flux6(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua) =           &
                      ( 37.*(q_i+q_im1) - 8.*(q_ip1+q_im2)       &
                     +(q_ip2+q_im3) )/60.0

   flux5(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua) =           &
           flux6(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua)     &
            -sign(1,time_step)*sign(1.,ua)*(                     &
              (q_ip2-q_im3)-5.*(q_ip1-q_im2)+10.*(q_i-q_im1) )/60.0
! END VERBATIM

   specified = .false.
   if(config_flags%specified .or. config_flags%nested) specified = .true.
   ktf=MIN(kte,kde-1)

! BEGIN VERBATIM WRF/dyn_em/module_advect_em.F
   degrade_xs = .true.
   degrade_xe = .true.
   degrade_ys = .true.
   degrade_ye = .true.

   IF( config_flags%periodic_x   .or. &
       config_flags%symmetric_xs .or. &
       (its > ids+3)                ) degrade_xs = .false.
   IF( config_flags%periodic_x   .or. &
       config_flags%symmetric_xe .or. &
       (ite < ide-2)                ) degrade_xe = .false.
   IF( config_flags%periodic_y   .or. &
       config_flags%symmetric_ys .or. &
       (jts > jds+3)                ) degrade_ys = .false.
   IF( config_flags%periodic_y   .or. &
       config_flags%symmetric_ye .or. &
       (jte < jde-4)                ) degrade_ye = .false.

!--------------- y - advection first

      i_start = its
      i_end   = ite
      IF ( config_flags%open_xs .or. specified ) i_start = MAX(ids+1,its)
      IF ( config_flags%open_xe .or. specified ) i_end   = MIN(ide-1,ite)
      IF ( config_flags%periodic_x ) i_start = its
      IF ( config_flags%periodic_x ) i_end = ite

      j_start = jts
      j_end   = MIN(jte,jde-1)

!  higher order flux has a 5 or 7 point stencil, so compute
!  bounds so we can switch to second order flux close to the boundary

      j_start_f = j_start
      j_end_f   = j_end+1

      IF(degrade_ys) then
        j_start = MAX(jts,jds+1)
        j_start_f = jds+3
      ENDIF

      IF(degrade_ye) then
        j_end = MIN(jte,jde-2)
        j_end_f = jde-3
      ENDIF

      IF(config_flags%polar) j_end = MIN(jte,jde-1)

!  compute fluxes, 5th or 6th order

     jp1 = 2
     jp0 = 1

     j_loop_y_flux_5 : DO j = j_start, j_end+1

      IF( (j >= j_start_f ) .and. (j <= j_end_f) ) THEN  ! use full stencil

        DO k=kts,ktf
        DO i = i_start, i_end
          vel = 0.5*(rv(i,k,j)+rv(i-1,k,j))
          fqy( i, k, jp1 ) = vel*flux5(               &
                  u(i,k,j-3), u(i,k,j-2), u(i,k,j-1),       &
                  u(i,k,j  ), u(i,k,j+1), u(i,k,j+2),  vel )
        ENDDO
        ENDDO

!  we must be close to some boundary where we need to reduce the order of the stencil

      ELSE IF ( j == jds+1 ) THEN   ! 2nd order flux next to south boundary

            DO k=kts,ktf
            DO i = i_start, i_end
              fqy(i, k, jp1) = 0.25*(rv(i,k,j)+rv(i-1,k,j))  &
                                     *(u(i,k,j)+u(i,k,j-1))
            ENDDO
            ENDDO

     ELSE IF  ( j == jds+2 ) THEN  ! third of 4th order flux 2 in from south boundary

            DO k=kts,ktf
            DO i = i_start, i_end
              vel = 0.5*(rv(i,k,j)+rv(i-1,k,j))
              fqy( i, k, jp1 ) = vel*flux3(      &
                   u(i,k,j-2),u(i,k,j-1), u(i,k,j),u(i,k,j+1),vel )
            ENDDO
            ENDDO

     ELSE IF ( j == jde-1 ) THEN  ! 2nd order flux next to north boundary

            DO k=kts,ktf
            DO i = i_start, i_end
              fqy(i, k, jp1) = 0.25*(rv(i,k,j)+rv(i-1,k,j))    &
                     *(u(i,k,j)+u(i,k,j-1))
            ENDDO
            ENDDO

     ELSE IF ( j == jde-2 ) THEN  ! 3rd order flux 2 in from north boundary

            DO k=kts,ktf
            DO i = i_start, i_end
              vel = 0.5*(rv(i,k,j)+rv(i-1,k,j))
              fqy( i, k, jp1 ) = vel*flux3(     &
                   u(i,k,j-2),u(i,k,j-1),    &
                   u(i,k,j),u(i,k,j+1),vel )
            ENDDO
            ENDDO

      END IF

!  y flux-divergence into tendency

        ! (j > j_start) will miss the u(,,jds) tendency
        IF ( config_flags%polar .AND. (j == jds+1) ) THEN
          DO k=kts,ktf
          DO i = i_start, i_end
            mrdy=msfux(i,j-1)*rdy   ! ADT eqn 44, 2nd term on RHS
            tendency(i,k,j-1) = tendency(i,k,j-1) - mrdy*fqy(i,k,jp1)
          END DO
          END DO
        ! This would be seen by (j > j_start) but we need to zero out the NP tendency
        ELSE IF( config_flags%polar .AND. (j == jde) ) THEN
          DO k=kts,ktf
          DO i = i_start, i_end
            mrdy=msfux(i,j-1)*rdy   ! ADT eqn 44, 2nd term on RHS
            tendency(i,k,j-1) = tendency(i,k,j-1) + mrdy*fqy(i,k,jp0)
          END DO
          END DO
        ELSE  ! normal code

        IF(j > j_start) THEN

          DO k=kts,ktf
          DO i = i_start, i_end
            mrdy=msfux(i,j-1)*rdy   ! ADT eqn 44, 2nd term on RHS
            tendency(i,k,j-1) = tendency(i,k,j-1) - mrdy*(fqy(i,k,jp1)-fqy(i,k,jp0))
          ENDDO
          ENDDO

        ENDIF

        END IF


        jtmp = jp1
        jp1 = jp0
        jp0 = jtmp

   ENDDO j_loop_y_flux_5
! END VERBATIM
END SUBROUTINE advect_u_yflux_orig


SUBROUTINE advect_u_yflux_gpu(u, rv, msfux, tendency, fqy3, rdy, time_step, config_flags, dev, &
                              ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
                              its, ite, jts, jte, kts, kte)
   TYPE(grid_config_rec_type), INTENT(IN) :: config_flags
   LOGICAL, INTENT(IN) :: dev
   INTEGER, INTENT(IN) :: ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: u, rv
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: tendency
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: fqy3     ! work array (was fqy(its:ite,kts:kte,2))
   REAL, DIMENSION(ims:ime, jms:jme), INTENT(IN) :: msfux
   REAL, INTENT(IN) :: rdy
   INTEGER, INTENT(IN) :: time_step
   INTEGER :: i, j, k, ktf
   INTEGER :: i_start, i_end, j_start, j_end, j_start_f, j_end_f
   REAL :: mrdy
   LOGICAL :: degrade_xs, degrade_ys, degrade_xe, degrade_ye, specified
#ifndef TMPL_NO_STMTFN
   REAL    :: flux3, flux4, flux5, flux6
#endif
   REAL    :: q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua, vel
#ifndef TMPL_NO_STMTFN
   flux4(q_im2, q_im1, q_i, q_ip1, ua) =                         &
          ( 7.*(q_i + q_im1) - (q_ip1 + q_im2) )/12.0

   flux3(q_im2, q_im1, q_i, q_ip1, ua) =                         &
            flux4(q_im2, q_im1, q_i, q_ip1, ua) +                &
            sign(1,time_step)*sign(1.,ua)*((q_ip1 - q_im2)-3.*(q_i-q_im1))/12.0

   flux6(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua) =           &
                      ( 37.*(q_i+q_im1) - 8.*(q_ip1+q_im2)       &
                     +(q_ip2+q_im3) )/60.0

   flux5(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua) =           &
           flux6(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua)     &
            -sign(1,time_step)*sign(1.,ua)*(                     &
              (q_ip2-q_im3)-5.*(q_ip1-q_im2)+10.*(q_i-q_im1) )/60.0
#endif

   specified = .false.
   if(config_flags%specified .or. config_flags%nested) specified = .true.
   ktf=MIN(kte,kde-1)

   ! host scalars: unchanged setup code of the source
   degrade_xs = .true.
   degrade_xe = .true.
   degrade_ys = .true.
   degrade_ye = .true.
   IF( config_flags%periodic_x   .or. config_flags%symmetric_xs .or. (its > ids+3) ) degrade_xs = .false.
   IF( config_flags%periodic_x   .or. config_flags%symmetric_xe .or. (ite < ide-2) ) degrade_xe = .false.
   IF( config_flags%periodic_y   .or. config_flags%symmetric_ys .or. (jts > jds+3) ) degrade_ys = .false.
   IF( config_flags%periodic_y   .or. config_flags%symmetric_ye .or. (jte < jde-4) ) degrade_ye = .false.
      i_start = its
      i_end   = ite
      IF ( config_flags%open_xs .or. specified ) i_start = MAX(ids+1,its)
      IF ( config_flags%open_xe .or. specified ) i_end   = MIN(ide-1,ite)
      IF ( config_flags%periodic_x ) i_start = its
      IF ( config_flags%periodic_x ) i_end = ite
      j_start = jts
      j_end   = MIN(jte,jde-1)
      j_start_f = j_start
      j_end_f   = j_end+1
      IF(degrade_ys) then
        j_start = MAX(jts,jds+1)
        j_start_f = jds+3
      ENDIF
      IF(degrade_ye) then
        j_end = MIN(jte,jde-2)
        j_end_f = jde-3
      ENDIF

   ! K-ADVU-Y1: face fluxes of rows j_start .. j_end+1
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(fqy3, u, rv) firstprivate(i_start, i_end, j_start, j_end, j_start_f, j_end_f, jds, jde, kts, ktf, time_step) &
!$omp& private(vel)
   DO j = j_start, j_end+1
   DO k=kts,ktf
   DO i = i_start, i_end
      IF( (j >= j_start_f ) .and. (j <= j_end_f) ) THEN  ! use full stencil
          vel = 0.5*(rv(i,k,j)+rv(i-1,k,j))
          fqy3( i, k, j ) = vel*flux5(               &
                  u(i,k,j-3), u(i,k,j-2), u(i,k,j-1),       &
                  u(i,k,j  ), u(i,k,j+1), u(i,k,j+2),  vel STMTFN_TS )
      ELSE IF ( j == jds+1 ) THEN   ! 2nd order flux next to south boundary
              fqy3(i, k, j) = 0.25*(rv(i,k,j)+rv(i-1,k,j))  &
                                     *(u(i,k,j)+u(i,k,j-1))
      ELSE IF  ( j == jds+2 ) THEN  ! third of 4th order flux 2 in from south boundary
              vel = 0.5*(rv(i,k,j)+rv(i-1,k,j))
              fqy3( i, k, j ) = vel*flux3(      &
                   u(i,k,j-2),u(i,k,j-1), u(i,k,j),u(i,k,j+1),vel STMTFN_TS )
      ELSE IF ( j == jde-1 ) THEN  ! 2nd order flux next to north boundary
              fqy3(i, k, j) = 0.25*(rv(i,k,j)+rv(i-1,k,j))    &
                     *(u(i,k,j)+u(i,k,j-1))
      ELSE IF ( j == jde-2 ) THEN  ! 3rd order flux 2 in from north boundary
              vel = 0.5*(rv(i,k,j)+rv(i-1,k,j))
              fqy3( i, k, j ) = vel*flux3(     &
                   u(i,k,j-2),u(i,k,j-1),    &
                   u(i,k,j),u(i,k,j+1),vel STMTFN_TS )
      END IF
   ENDDO
   ENDDO
   ENDDO

   ! K-ADVU-Y2: flux divergence of rows j_start .. j_end (the source's j-1)
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(tendency, fqy3, msfux) firstprivate(i_start, i_end, j_start, j_end, kts, ktf, rdy) private(mrdy)
   DO j = j_start+1, j_end+1
   DO k=kts,ktf
   DO i = i_start, i_end
            mrdy=msfux(i,j-1)*rdy   ! ADT eqn 44, 2nd term on RHS
            tendency(i,k,j-1) = tendency(i,k,j-1) - mrdy*(fqy3(i,k,j)-fqy3(i,k,j-1))
   ENDDO
   ENDDO
   ENDDO
END SUBROUTINE advect_u_yflux_gpu

#ifdef TMPL_NO_STMTFN
! The statement functions of advect_u as module functions (fallback when probe
! F-STMTFN fails): identical expressions; time_step is an argument.
PURE REAL FUNCTION flux4(q_im2, q_im1, q_i, q_ip1, ua)
!$omp declare target
   REAL, INTENT(IN) :: q_im2, q_im1, q_i, q_ip1, ua
   flux4 = ( 7.*(q_i + q_im1) - (q_ip1 + q_im2) )/12.0
END FUNCTION flux4

PURE REAL FUNCTION flux3(q_im2, q_im1, q_i, q_ip1, ua, time_step)
!$omp declare target
   REAL, INTENT(IN) :: q_im2, q_im1, q_i, q_ip1, ua
   INTEGER, INTENT(IN) :: time_step
   flux3 = flux4(q_im2, q_im1, q_i, q_ip1, ua) +                &
            sign(1,time_step)*sign(1.,ua)*((q_ip1 - q_im2)-3.*(q_i-q_im1))/12.0
END FUNCTION flux3

PURE REAL FUNCTION flux6(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua)
!$omp declare target
   REAL, INTENT(IN) :: q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua
   flux6 = ( 37.*(q_i+q_im1) - 8.*(q_ip1+q_im2)       &
                     +(q_ip2+q_im3) )/60.0
END FUNCTION flux6

PURE REAL FUNCTION flux5(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua, time_step)
!$omp declare target
   REAL, INTENT(IN) :: q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua
   INTEGER, INTENT(IN) :: time_step
   flux5 = flux6(q_im3, q_im2, q_im1, q_i, q_ip1, q_ip2, ua)     &
            -sign(1,time_step)*sign(1.,ua)*(                     &
              (q_ip2-q_im3)-5.*(q_ip1-q_im2)+10.*(q_i-q_im1) )/60.0
END FUNCTION flux5
#endif

END MODULE tb_mod


PROGRAM t_tmpl_b
   USE tb_mod
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: ids = 1, ide = 31, jds = 1, jde = 41, kds = 1, kde = 16
   INTEGER, PARAMETER :: ims = -4, ime = 36, jms = -4, jme = 46, kms = 1, kme = 16
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: u, rv, t0, ta, tb, tc, fqy3
   REAL, DIMENSION(ims:ime, jms:jme) :: msfux
   TYPE(grid_config_rec_type) :: cf
   INTEGER :: irep, nrep, nbad, it, nargs, time_step
   INTEGER :: tiles(4, 5)
   REAL :: rdy
   CHARACTER(LEN=16) :: arg, allow
   LOGICAL :: on_host
   ! tile (its, ite, jts, jte): single tile, south edge, north edge, interior, near-south
   tiles(:,1) = (/ ids, ide, jds, jde /)
   tiles(:,2) = (/ ids, ide, jds, 20 /)
   tiles(:,3) = (/ ids, ide, 21, jde /)
   tiles(:,4) = (/ 5, 20, 11, 30 /)
   tiles(:,5) = (/ 1, 15, 4, 25 /)
   nrep = 20
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) nrep
   END IF
   on_host = .TRUE.
!$omp target map(from: on_host)
   on_host = omp_is_initial_device()
!$omp end target
   CALL GET_ENVIRONMENT_VARIABLE('ALLOW_HOST', allow)
   IF (on_host .AND. TRIM(allow) /= '1') THEN
      PRINT '(a)', 'FAIL  T-TMPL-B: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
      STOP 2
   END IF
   PRINT '(a,a)', 'note: target regions run on the ', MERGE('host', 'GPU ', on_host)
   CALL RANDOM_SEED()
   nbad = 0
   DO irep = 1, nrep
      CALL RANDOM_NUMBER(u); u = 20.*(u - 0.5)
      CALL RANDOM_NUMBER(rv); rv = 2000.*(rv - 0.5)
      IF (MOD(irep, 2) == 0) THEN
         rv(3:6, 2:5, 7:9) = 0.; rv(8, 3, 12) = -0.      ! zero and -0.0 velocities (sign(1.,ua))
      END IF
      CALL RANDOM_NUMBER(t0)
      CALL RANDOM_NUMBER(msfux); msfux = 0.95 + 0.1*msfux
      rdy = 1./100.
      time_step = MERGE(1, -1, MOD(irep, 3) /= 0)      ! sign(1,time_step)
      DO it = 1, 5
         ta = t0; tb = t0; tc = t0
         CALL advect_u_yflux_orig(u, rv, msfux, ta, rdy, time_step, cf, ids, ide, jds, jde, kds, kde, &
              ims, ime, jms, jme, kms, kme, tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), kds, kde)
         fqy3 = 0.
         CALL advect_u_yflux_gpu(u, rv, msfux, tb, fqy3, rdy, time_step, cf, .FALSE., ids, ide, jds, jde, kds, kde, &
              ims, ime, jms, jme, kms, kme, tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), kds, kde)
!$omp target data map(to: u, rv, msfux) map(tofrom: tc) map(alloc: fqy3)
         CALL advect_u_yflux_gpu(u, rv, msfux, tc, fqy3, rdy, time_step, cf, .TRUE., ids, ide, jds, jde, kds, kde, &
              ims, ime, jms, jme, kms, kme, tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), kds, kde)
!$omp end target data
         nbad = nbad + COUNT(TRANSFER(ta, 1, SIZE(ta)) /= TRANSFER(tb, 1, SIZE(tb))) &
                     + COUNT(TRANSFER(ta, 1, SIZE(ta)) /= TRANSFER(tc, 1, SIZE(tc)))
         IF (irep == 1 .AND. COUNT(ta /= t0) == 0) THEN
            PRINT '(a,i0)', 'FAIL  T-TMPL-B: the original changed nothing for tile ', it
            nbad = nbad + 1
         END IF
      END DO
   END DO
   PRINT '(a,i0,a)', 'T-TMPL-B: ', nrep, ' random fields x 5 tile positions'
   IF (nbad == 0) THEN
      PRINT '(a)', 'PASS  T-TMPL-B (rolling-buffer y-flux vs Y1/Y2 kernels: bit-identical tendency)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-TMPL-B: ', nbad, ' differing values'
      STOP 1
   END IF
END PROGRAM t_tmpl_b
