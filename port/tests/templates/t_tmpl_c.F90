! Template C (plan.md 7.0/7.1, kernels K-PREP-5a / K-PREP-5b): a routine whose
! j-loop body holds per-j slabs (dmdt(its:ite), divv(its:ite,kts:kte)) and a
! vertical recurrence becomes a column kernel, one thread per (i,j).
!
! calc_ww_cp (WRF/dyn_em/module_big_step_utilities_em.F, verbatim below):
!   muu, muv          two pointwise 2D loops           -> K-PREP-5a (x2), work arrays
!   per j:  i = its..ite:  dmdt(i)=0, ww(i,1,j)=0, ww(i,kte,j)=0
!           k = kts..ktf, i = its..itf: divv(i,k) = ...; dmdt(i) += divv(i,k)
!           k = 2..ktf,   i = its..itf: ww(i,k,j) = ww(i,k-1,j) - ... - divv(i,k-1)
!                                                    -> K-PREP-5b, one column kernel
! Column rules used here (CODING_STANDARD.md, Template C):
!   - dmdt(i) becomes the private scalar dmdts; divv(i,k) the private fixed-size
!     column divv_col(k) (size WRF_KMAX, never a runtime-sized private);
!   - the kernel runs i over the UNION of the ranges (its..ite) and each
!     statement group keeps its own range with an IF (i <= itf) guard;
!   - inside a column the statement groups run in source order; the k loops
!     keep their direction and order (the dmdt sum is summed in k order).
!
! The test compares ww bit for bit (the whole array, prefilled) for several
! tile positions, on the host and in target regions.
! Usage: t_tmpl_c [nrep]; ALLOW_HOST=1 for host-only.

MODULE tc_mod
   IMPLICIT NONE
   INTEGER, PARAMETER :: WRF_KMAX = 64
CONTAINS

! BEGIN VERBATIM WRF/dyn_em/module_big_step_utilities_em.F
SUBROUTINE calc_ww_cp ( u, v, mup, mub, c1h, c2h, ww,    &
                        rdx, rdy, msftx, msfty,          &
                        msfux, msfuy, msfvx, msfvx_inv,  &
                        msfvy, dnw,                      &
                        ids, ide, jds, jde, kds, kde,    &
                        ims, ime, jms, jme, kms, kme,    &
                        its, ite, jts, jte, kts, kte    )

   IMPLICIT NONE

   ! Input data


   INTEGER ,    INTENT(IN   ) :: ids, ide, jds, jde, kds, kde, &
                                 ims, ime, jms, jme, kms, kme, &
                                 its, ite, jts, jte, kts, kte

   REAL , DIMENSION( ims:ime , kms:kme , jms:jme ) , INTENT(IN   ) :: u, v
   REAL , DIMENSION( ims:ime , jms:jme ) , INTENT(IN   ) :: mup, mub, &
                                                            msftx, msfty, &
                                                            msfux, msfuy, &
                                                            msfvx, msfvy, &
                                                            msfvx_inv
   REAL , DIMENSION( kms:kme ) , INTENT(IN   ) :: dnw
   REAL , DIMENSION( kms:kme ) , INTENT(IN   ) :: c1h, c2h
   
   REAL , DIMENSION( ims:ime , kms:kme , jms:jme ) , INTENT(OUT  ) :: ww
   REAL , INTENT(IN   )  :: rdx, rdy
   
   ! Local data
   
   INTEGER :: i, j, k, itf, jtf, ktf
   REAL , DIMENSION( its:ite ) :: dmdt
   REAL , DIMENSION( its:ite, kts:kte ) :: divv
   REAL , DIMENSION( its:ite+1, jts:jte+1 ) :: muu, muv

!<DESCRIPTION>
!
!  calc_ww calculates omega using the velocities (u,v) and the dry-air
!  column mass (mup+mub).
!  The algorithm integrates the continuity equation through the column
!  followed by a diagnosis of omega.
!
!</DESCRIPTION>

!<DESCRIPTION>
!
!  calc_ww_cp calculates omega using the velocities (u,v) and the
!  column mass mu.
!
!</DESCRIPTION>

    jtf=MIN(jte,jde-1)
    ktf=MIN(kte,kde-1)  
    itf=MIN(ite,ide-1)

!  mu coupled with the appropriate map factor

      DO j=jts,jtf
      DO i=its,min(ite+1,ide)
        MUU(i,j) = 0.5*(MUP(i,j)+MUB(i,j)+MUP(i-1,j)+MUB(i-1,j))
      ENDDO
      ENDDO

      DO j=jts,min(jte+1,jde)
      DO i=its,itf
        MUV(i,j) = 0.5*(MUP(i,j)+MUB(i,j)+MUP(i,j-1)+MUB(i,j-1))
      ENDDO
      ENDDO

      DO j=jts,jtf

        DO i=its,ite
          dmdt(i) = 0.
          ww(i,1,j) = 0.
          ww(i,kte,j) = 0.
        ENDDO

!       Comments on the modifications for map scale factors
!       ADT eqn 47 / my (putting rho -> 'mu') is:
!       (1/my) partial d mu/dt = -mx partial d/dx(mu u/my)
!                                -mx partial d/dy(mu v/mx)
!                                -partial d/dz(mu w/my)
!
!       Using nu instead of z the last term becomes:
!                                -partial d/dnu((c1(k)*mu(dnu/dt))/my)
!
!       Integrating with respect to nu over ALL levels, with dnu/dt=0 at top
!       and bottom, the last term becomes = 0
!
!       Integral|bot->top[(1/my) partial d mu/dt]dnu =
!       Integral|bot->top[-mx partial d/dx(mu u/my)
!                         -mx partial d/dy(mu v/mx)]dnu
!
!       muu='mu'[on u]/my, muv='mu'[on v]/mx
!       (1/my) partial d mu/dt is independent of nu
!         => LHS = Integral|bot->top[con]dnu = conservation*(-1) = -dmdt
!
!         => dmdt = mx*Integral|bot->top[partial d/dx(mu u/my) +
!                                        partial d/dy(mu v/mx)]dnu
!         => dmdt = sum_bot->top[divv]
!       where
!         divv=mx*[partial d/dx(mu u/my) + partial d/dy(mu v/mx)]*delta nu

        DO k=kts,ktf
        DO i=its,itf

          divv(i,k) = msftx(i,j)*dnw(k)*( rdx*((c1h(k)*muu(i+1,j)+c2h(k))*u(i+1,k,j)/msfuy(i+1,j)-(c1h(k)*muu(i,j)+c2h(k))*u(i,k,j)/msfuy(i,j))  &
                                        +rdy*((c1h(k)*muv(i,j+1)+c2h(k))*v(i,k,j+1)*msfvx_inv(i,j+1)-(c1h(k)*muv(i,j)+c2h(k))*v(i,k,j)*msfvx_inv(i,j))   )

!          dmdt(i) = dmdt(i) + dnw(k)* ( rdx*(ru(i+1,k,j)-ru(i,k,j))  &
!                                       +rdy*(rv(i,k,j+1)-rv(i,k,j))   )

          dmdt(i) = dmdt(i) + divv(i,k)


        ENDDO
        ENDDO

!       Further map scale factor notes:
!       Now integrate from bottom to top, level by level:
!       mu dnu/dt/my [k+1] = mu dnu/dt/my [k] + [-(1/my) partial d mu/dt
!                           -mx partial d/dx(mu u/my)
!                           -mx partial d/dy(mu v/mx)]*dnu[k->k+1]
!       ww [k+1] = ww [k] -(1/my) partial d mu/dt * dnu[k->k+1] - divv[k]
!                = ww [k] -dmdt * dnw[k] - divv[k]

        DO k=2,ktf
        DO i=its,itf

!           ww(i,k,j)=ww(i,k-1,j)                                       &
!                        - dnw(k-1)* ( dmdt(i)                          &
!                                     +rdx*(ru(i+1,k-1,j)-ru(i,k-1,j))  &
!                                     +rdy*(rv(i,k-1,j+1)-rv(i,k-1,j)) )

           ww(i,k,j)=ww(i,k-1,j) - dnw(k-1)*c1h(k-1)*dmdt(i) - divv(i,k-1)

        ENDDO
        ENDDO
     ENDDO


END SUBROUTINE calc_ww_cp
! END VERBATIM


SUBROUTINE calc_ww_cp_gpu ( u, v, mup, mub, c1h, c2h, ww,    &
                        rdx, rdy, msftx, msfty,          &
                        msfux, msfuy, msfvx, msfvx_inv,  &
                        msfvy, dnw,                      &
                        muu, muv, dev,                   &
                        ids, ide, jds, jde, kds, kde,    &
                        ims, ime, jms, jme, kms, kme,    &
                        its, ite, jts, jte, kts, kte    )
   IMPLICIT NONE
   INTEGER ,    INTENT(IN   ) :: ids, ide, jds, jde, kds, kde, &
                                 ims, ime, jms, jme, kms, kme, &
                                 its, ite, jts, jte, kts, kte
   LOGICAL , INTENT(IN) :: dev
   REAL , DIMENSION( ims:ime , kms:kme , jms:jme ) , INTENT(IN   ) :: u, v
   REAL , DIMENSION( ims:ime , jms:jme ) , INTENT(IN   ) :: mup, mub, &
                                                            msftx, msfty, &
                                                            msfux, msfuy, &
                                                            msfvx, msfvy, &
                                                            msfvx_inv
   REAL , DIMENSION( kms:kme ) , INTENT(IN   ) :: dnw
   REAL , DIMENSION( kms:kme ) , INTENT(IN   ) :: c1h, c2h
   REAL , DIMENSION( ims:ime , kms:kme , jms:jme ) , INTENT(OUT  ) :: ww
   REAL , INTENT(IN   )  :: rdx, rdy
   ! work arrays (were the locals muu, muv(its:ite+1, jts:jte+1))
   REAL , DIMENSION( ims:ime , jms:jme ) , INTENT(INOUT) :: muu, muv

   INTEGER :: i, j, k, itf, jtf, ktf
   REAL :: dmdts                       ! was dmdt(its:ite)
   REAL :: divv_col(WRF_KMAX)          ! was divv(its:ite, kts:kte)

    jtf=MIN(jte,jde-1)
    ktf=MIN(kte,kde-1)
    itf=MIN(ite,ide-1)

   ! K-PREP-5a (1)
!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) &
!$omp& shared(muu, mup, mub) firstprivate(its, ite, jts, jtf, ide)
      DO j=jts,jtf
      DO i=its,min(ite+1,ide)
        MUU(i,j) = 0.5*(MUP(i,j)+MUB(i,j)+MUP(i-1,j)+MUB(i-1,j))
      ENDDO
      ENDDO

   ! K-PREP-5a (2)
!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) &
!$omp& shared(muv, mup, mub) firstprivate(its, itf, jts, jte, jde)
      DO j=jts,min(jte+1,jde)
      DO i=its,itf
        MUV(i,j) = 0.5*(MUP(i,j)+MUB(i,j)+MUP(i,j-1)+MUB(i,j-1))
      ENDDO
      ENDDO

   ! K-PREP-5b: one thread per column; i over the union its..ite
!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) &
!$omp& shared(ww, u, v, muu, muv, msftx, msfuy, msfvx_inv, dnw, c1h, c2h) &
!$omp& firstprivate(its, ite, itf, jts, jtf, kts, kte, ktf, rdx, rdy) private(k, dmdts, divv_col)
      DO j=jts,jtf
      DO i=its,ite

          dmdts = 0.
          ww(i,1,j) = 0.
          ww(i,kte,j) = 0.

        IF (i <= itf) THEN
        DO k=kts,ktf
          divv_col(k) = msftx(i,j)*dnw(k)*( rdx*((c1h(k)*muu(i+1,j)+c2h(k))*u(i+1,k,j)/msfuy(i+1,j)-(c1h(k)*muu(i,j)+c2h(k))*u(i,k,j)/msfuy(i,j))  &
                                        +rdy*((c1h(k)*muv(i,j+1)+c2h(k))*v(i,k,j+1)*msfvx_inv(i,j+1)-(c1h(k)*muv(i,j)+c2h(k))*v(i,k,j)*msfvx_inv(i,j))   )
          dmdts = dmdts + divv_col(k)
        ENDDO

        DO k=2,ktf
           ww(i,k,j)=ww(i,k-1,j) - dnw(k-1)*c1h(k-1)*dmdts - divv_col(k-1)
        ENDDO
        END IF

      ENDDO
      ENDDO
END SUBROUTINE calc_ww_cp_gpu

END MODULE tc_mod


PROGRAM t_tmpl_c
   USE tc_mod
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: ids = 1, ide = 31, jds = 1, jde = 26, kds = 1, kde = 21
   INTEGER, PARAMETER :: ims = -4, ime = 36, jms = -4, jme = 31, kms = 1, kme = 21
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: u, v, w0, wa, wb, wc
   REAL, DIMENSION(ims:ime, jms:jme) :: mup, mub, msftx, msfty, msfux, msfuy, msfvx, msfvy, msfvx_inv, muu, muv
   REAL, DIMENSION(kms:kme) :: dnw, c1h, c2h
   REAL :: rdx, rdy
   INTEGER :: irep, nrep, nbad, it, nargs, tiles(6, 4)
   CHARACTER(LEN=16) :: arg, allow
   LOGICAL :: on_host
   ! (its, ite, jts, jte, kts, kte): single tile (staggered ends), interior, east/north edge, south-west
   tiles(:,1) = (/ ids, ide, jds, jde, kds, kde /)
   tiles(:,2) = (/ 6, 20, 5, 15, kds, kde /)
   tiles(:,3) = (/ 16, ide, 12, jde, kds, kde /)
   tiles(:,4) = (/ ids, 12, jds, 10, kds, kde /)
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
      PRINT '(a)', 'FAIL  T-TMPL-C: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
      STOP 2
   END IF
   PRINT '(a,a)', 'note: target regions run on the ', MERGE('host', 'GPU ', on_host)
   CALL RANDOM_SEED()
   nbad = 0
   DO irep = 1, nrep
      CALL RANDOM_NUMBER(u); u = 30.*(u - 0.5)
      CALL RANDOM_NUMBER(v); v = 30.*(v - 0.5)
      CALL RANDOM_NUMBER(mup); mup = 50.*(mup - 0.5)
      CALL RANDOM_NUMBER(mub); mub = 90000. + 5000.*mub
      CALL RANDOM_NUMBER(msftx); msftx = 0.95 + 0.1*msftx
      CALL RANDOM_NUMBER(msfty); msfty = 0.95 + 0.1*msfty
      CALL RANDOM_NUMBER(msfux); msfux = 0.95 + 0.1*msfux
      CALL RANDOM_NUMBER(msfuy); msfuy = 0.95 + 0.1*msfuy
      CALL RANDOM_NUMBER(msfvx); msfvx = 0.95 + 0.1*msfvx
      CALL RANDOM_NUMBER(msfvy); msfvy = 0.95 + 0.1*msfvy
      msfvx_inv = 1./msfvx
      CALL RANDOM_NUMBER(dnw); dnw = -0.01 - 0.05*dnw
      CALL RANDOM_NUMBER(c1h); CALL RANDOM_NUMBER(c2h); c2h = 100.*c2h
      rdx = 1./900.; rdy = 1./900.
      CALL RANDOM_NUMBER(w0)
      DO it = 1, 4
         wa = w0; wb = w0; wc = w0
         CALL calc_ww_cp(u, v, mup, mub, c1h, c2h, wa, rdx, rdy, msftx, msfty, msfux, msfuy, msfvx, msfvx_inv, &
              msfvy, dnw, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
              tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), tiles(5,it), tiles(6,it))
         muu = 0.; muv = 0.
         CALL calc_ww_cp_gpu(u, v, mup, mub, c1h, c2h, wb, rdx, rdy, msftx, msfty, msfux, msfuy, msfvx, msfvx_inv, &
              msfvy, dnw, muu, muv, .FALSE., ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
              tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), tiles(5,it), tiles(6,it))
!$omp target data map(to: u, v, mup, mub, c1h, c2h, msftx, msfty, msfux, msfuy, msfvx, msfvx_inv, msfvy, dnw) &
!$omp&            map(tofrom: wc) map(alloc: muu, muv)
         CALL calc_ww_cp_gpu(u, v, mup, mub, c1h, c2h, wc, rdx, rdy, msftx, msfty, msfux, msfuy, msfvx, msfvx_inv, &
              msfvy, dnw, muu, muv, .TRUE., ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
              tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), tiles(5,it), tiles(6,it))
!$omp end target data
         nbad = nbad + COUNT(TRANSFER(wa, 1, SIZE(wa)) /= TRANSFER(wb, 1, SIZE(wb))) &
                     + COUNT(TRANSFER(wa, 1, SIZE(wa)) /= TRANSFER(wc, 1, SIZE(wc)))
      END DO
   END DO
   PRINT '(a,i0,a)', 'T-TMPL-C: ', nrep, ' random fields x 4 tile positions'
   IF (nbad == 0) THEN
      PRINT '(a)', 'PASS  T-TMPL-C (calc_ww_cp slab loops vs column kernel: bit-identical ww)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-TMPL-C: ', nbad, ' differing values'
      STOP 1
   END IF
END PROGRAM t_tmpl_c
