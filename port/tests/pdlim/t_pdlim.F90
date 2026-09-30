! T-PDLIM (plan.md 7.5, kernels K-PD-L3a / K-PD-L3b): the positive-definite
! flux limiter of advect_scalar_pd, split into a per-cell kernel and per-face
! kernels, must give bit-identical fluxes to the original loop.
!
! pdlim_original  : the three limiter loops of advect_scalar_pd, copied
!                   verbatim from WRF v4.6.0 dyn_em/module_advect_em.F
!                   (lines 7724-7780): ph_low, flux_out, then the scaling loop
!                   that updates up to six faces per cell.
! pdlim_split     : the reference split for the GPU (use exactly this in
!                   advect_scalar_pd under #ifdef WRF_GPU):
!    L1/L2 (ph_low, flux_out): unchanged pointwise loops
!    L3a  per cell over the SAME range as the original loop
!             lim(i,k,j) = flux_out(i,k,j) > ph_low(i,k,j)
!             if lim: scl(i,k,j) = max(0.,ph_low(i,k,j)/(flux_out(i,k,j)+eps))
!    L3b  per face, three kernels (x, y, z).  A face is scaled only by its
!         donor cell (the cell the flux leaves), and only if that donor is
!         inside the original cell range and limited:
!           x-face f (f = i_start .. i_end+1):
!             fqx(f) > 0: donor f-1   (the original's "fqx(i+1) > 0" of cell i=f-1)
!             fqx(f) < 0: donor f     (the original's "fqx(i) < 0"   of cell i=f)
!           y-face: the same with j
!           z-face k (k = kts .. ktf+1), sign reversed (mass coordinate):
!             fqz(k) < 0: donor k-1   (the original's "fqz(k+1) < 0" of cell k-1)
!             fqz(k) > 0: donor k     (the original's "fqz(k) > 0"   of cell k)
!         A zero, -0.0 or NaN flux is never scaled (both tests are strict),
!         as in the original.  An explicit logical 'lim' is used instead of a
!         sentinel value in scl, because max(0.,NaN) is processor dependent.
!    Why this is exact: in the original each face is scaled at most once, by
!    its donor.  Scaling by scale >= 0 never changes the sign of a flux, so
!    the neighbour's test (the opposite sign) stays false after the donor
!    has scaled the face; flux_out and ph_low are not updated inside the
!    loop.  Each face therefore gets the same single multiplication.
!
! The test runs random fields (and zeros, -0.0, NaN, fluxes near the range
! edges) through the original (host), the split version on the host and the
! split version in target regions, and compares fqx, fqy, fqz bit for bit.
! Usage: t_pdlim [ncases]  (default 200).  With nvfortran the target regions
! run on the GPU; with gfortran (COMPILER=gnu) on the host.

MODULE pdlim_mod
   IMPLICIT NONE
CONTAINS

   SUBROUTINE pdlim_original(fqx, fqy, fqz, fqxl, fqyl, fqzl, field_old, mub, mu_old, c1, c2, &
                             msftx, msfty, rdzw, rdx, rdy, dt, eps, ph_low, flux_out, &
                             ims, ime, kms, kme, jms, jme, i_start, i_end, j_start, j_end, kts, ktf)
      INTEGER, INTENT(IN) :: ims, ime, kms, kme, jms, jme, i_start, i_end, j_start, j_end, kts, ktf
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: fqx, fqy, fqz
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: fqxl, fqyl, fqzl, field_old
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(OUT) :: ph_low, flux_out
      REAL, DIMENSION(ims:ime, jms:jme), INTENT(IN) :: mub, mu_old, msftx, msfty
      REAL, DIMENSION(kms:kme), INTENT(IN) :: c1, c2, rdzw
      REAL, INTENT(IN) :: rdx, rdy, dt, eps
      INTEGER :: i, j, k
      REAL :: scale

! BEGIN VERBATIM WRF/dyn_em/module_advect_em.F
   DO j=j_start, j_end
   DO k=kts, ktf
   DO i=i_start, i_end

     ph_low(i,k,j) = ((c1(k)*mub(i,j)+c2(k))+(c1(k)*mu_old(i,j)))*field_old(i,k,j) &
                - dt*( msftx(i,j)*msfty(i,j)*(               &
                       rdx*(fqxl(i+1,k,j)-fqxl(i,k,j)) +     &
                       rdy*(fqyl(i,k,j+1)-fqyl(i,k,j))  )    &
                      +msfty(i,j)*rdzw(k)*(fqzl(i,k+1,j)-fqzl(i,k,j)) )

   ENDDO
   ENDDO
   ENDDO

   DO j=j_start, j_end
   DO k=kts, ktf
   DO i=i_start, i_end

     flux_out(i,k,j) = dt*( (msftx(i,j)*msfty(i,j))*( &
                                rdx*(  max(0.,fqx (i+1,k,j))      &
                                      -min(0.,fqx (i  ,k,j)) )    &
                               +rdy*(  max(0.,fqy (i,k,j+1))      &
                                      -min(0.,fqy (i,k,j  )) ) )  &
                +msfty(i,j)*rdzw(k)*(  min(0.,fqz (i,k+1,j))      &
                                      -max(0.,fqz (i,k  ,j)) )   )

   ENDDO
   ENDDO
   ENDDO

   DO j=j_start, j_end
   DO k=kts, ktf
   DO i=i_start, i_end
     IF( flux_out(i,k,j) .gt. ph_low(i,k,j) ) THEN
       scale = max(0.,ph_low(i,k,j)/(flux_out(i,k,j)+eps))
       IF( fqx (i+1,k,j) .gt. 0.) fqx(i+1,k,j) = scale*fqx(i+1,k,j)
       IF( fqx (i  ,k,j) .lt. 0.) fqx(i  ,k,j) = scale*fqx(i  ,k,j)
       IF( fqy (i,k,j+1) .gt. 0.) fqy(i,k,j+1) = scale*fqy(i,k,j+1)
       IF( fqy (i,k,j  ) .lt. 0.) fqy(i,k,j  ) = scale*fqy(i,k,j  )
       IF( fqz (i,k+1,j) .lt. 0.) fqz(i,k+1,j) = scale*fqz(i,k+1,j)
       IF( fqz (i,k  ,j) .gt. 0.) fqz(i,k  ,j) = scale*fqz(i,k  ,j)

     END IF

   ENDDO
   ENDDO
   ENDDO
! END VERBATIM
   END SUBROUTINE pdlim_original


   SUBROUTINE pdlim_split(fqx, fqy, fqz, fqxl, fqyl, fqzl, field_old, mub, mu_old, c1, c2, &
                          msftx, msfty, rdzw, rdx, rdy, dt, eps, ph_low, flux_out, scl, lim, &
                          ims, ime, kms, kme, jms, jme, i_start, i_end, j_start, j_end, kts, ktf, dev)
      INTEGER, INTENT(IN) :: ims, ime, kms, kme, jms, jme, i_start, i_end, j_start, j_end, kts, ktf
      LOGICAL, INTENT(IN) :: dev
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: fqx, fqy, fqz
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: fqxl, fqyl, fqzl, field_old
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(OUT) :: ph_low, flux_out, scl
      LOGICAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(OUT) :: lim
      REAL, DIMENSION(ims:ime, jms:jme), INTENT(IN) :: mub, mu_old, msftx, msfty
      REAL, DIMENSION(kms:kme), INTENT(IN) :: c1, c2, rdzw
      REAL, INTENT(IN) :: rdx, rdy, dt, eps
      INTEGER :: i, j, k

!$omp target data map(tofrom: fqx, fqy, fqz) map(to: fqxl, fqyl, fqzl, field_old, mub, mu_old, c1, c2, &
!$omp&   msftx, msfty, rdzw) map(from: ph_low, flux_out, scl, lim) if(dev)

      ! K-PD-L1: ph_low (unchanged expression)
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(ph_low, c1, c2, mub, mu_old, field_old, msftx, msfty, fqxl, fqyl, fqzl, rdzw) &
!$omp& firstprivate(i_start, i_end, j_start, j_end, kts, ktf, dt, rdx, rdy)
      DO j = j_start, j_end
      DO k = kts, ktf
      DO i = i_start, i_end
        ph_low(i,k,j) = ((c1(k)*mub(i,j)+c2(k))+(c1(k)*mu_old(i,j)))*field_old(i,k,j) &
                   - dt*( msftx(i,j)*msfty(i,j)*(               &
                          rdx*(fqxl(i+1,k,j)-fqxl(i,k,j)) +     &
                          rdy*(fqyl(i,k,j+1)-fqyl(i,k,j))  )    &
                         +msfty(i,j)*rdzw(k)*(fqzl(i,k+1,j)-fqzl(i,k,j)) )
      ENDDO
      ENDDO
      ENDDO

      ! K-PD-L2: flux_out (unchanged expression)
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(flux_out, msftx, msfty, fqx, fqy, fqz, rdzw) &
!$omp& firstprivate(i_start, i_end, j_start, j_end, kts, ktf, dt, rdx, rdy)
      DO j = j_start, j_end
      DO k = kts, ktf
      DO i = i_start, i_end
        flux_out(i,k,j) = dt*( (msftx(i,j)*msfty(i,j))*( &
                                   rdx*(  max(0.,fqx (i+1,k,j))      &
                                         -min(0.,fqx (i  ,k,j)) )    &
                                  +rdy*(  max(0.,fqy (i,k,j+1))      &
                                         -min(0.,fqy (i,k,j  )) ) )  &
                   +msfty(i,j)*rdzw(k)*(  min(0.,fqz (i,k+1,j))      &
                                         -max(0.,fqz (i,k  ,j)) )   )
      ENDDO
      ENDDO
      ENDDO

      ! K-PD-L3a: which cells are limited, and their scale factor
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(lim, scl, flux_out, ph_low) firstprivate(i_start, i_end, j_start, j_end, kts, ktf, eps)
      DO j = j_start, j_end
      DO k = kts, ktf
      DO i = i_start, i_end
        lim(i,k,j) = flux_out(i,k,j) .gt. ph_low(i,k,j)
        IF (lim(i,k,j)) THEN
          scl(i,k,j) = max(0.,ph_low(i,k,j)/(flux_out(i,k,j)+eps))
        ELSE
          scl(i,k,j) = 0.
        END IF
      ENDDO
      ENDDO
      ENDDO

      ! K-PD-L3b (x): faces i_start .. i_end+1, scaled by their donor cell
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(fqx, lim, scl) firstprivate(i_start, i_end, j_start, j_end, kts, ktf)
      DO j = j_start, j_end
      DO k = kts, ktf
      DO i = i_start, i_end+1
        IF (fqx(i,k,j) .gt. 0.) THEN
          IF (i-1 >= i_start) THEN
            IF (lim(i-1,k,j)) fqx(i,k,j) = scl(i-1,k,j)*fqx(i,k,j)
          END IF
        ELSE IF (fqx(i,k,j) .lt. 0.) THEN
          IF (i <= i_end) THEN
            IF (lim(i,k,j)) fqx(i,k,j) = scl(i,k,j)*fqx(i,k,j)
          END IF
        END IF
      ENDDO
      ENDDO
      ENDDO

      ! K-PD-L3b (y): faces j_start .. j_end+1
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(fqy, lim, scl) firstprivate(i_start, i_end, j_start, j_end, kts, ktf)
      DO j = j_start, j_end+1
      DO k = kts, ktf
      DO i = i_start, i_end
        IF (fqy(i,k,j) .gt. 0.) THEN
          IF (j-1 >= j_start) THEN
            IF (lim(i,k,j-1)) fqy(i,k,j) = scl(i,k,j-1)*fqy(i,k,j)
          END IF
        ELSE IF (fqy(i,k,j) .lt. 0.) THEN
          IF (j <= j_end) THEN
            IF (lim(i,k,j)) fqy(i,k,j) = scl(i,k,j)*fqy(i,k,j)
          END IF
        END IF
      ENDDO
      ENDDO
      ENDDO

      ! K-PD-L3b (z): faces kts .. ktf+1, sign reversed
!$omp target teams distribute parallel do collapse(3) if(target: dev) default(none) &
!$omp& shared(fqz, lim, scl) firstprivate(i_start, i_end, j_start, j_end, kts, ktf)
      DO j = j_start, j_end
      DO k = kts, ktf+1
      DO i = i_start, i_end
        IF (fqz(i,k,j) .lt. 0.) THEN
          IF (k-1 >= kts) THEN
            IF (lim(i,k-1,j)) fqz(i,k,j) = scl(i,k-1,j)*fqz(i,k,j)
          END IF
        ELSE IF (fqz(i,k,j) .gt. 0.) THEN
          IF (k <= ktf) THEN
            IF (lim(i,k,j)) fqz(i,k,j) = scl(i,k,j)*fqz(i,k,j)
          END IF
        END IF
      ENDDO
      ENDDO
      ENDDO
!$omp end target data
   END SUBROUTINE pdlim_split

END MODULE pdlim_mod


PROGRAM t_pdlim
   USE pdlim_mod
   USE, INTRINSIC :: ieee_arithmetic
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: ims = -2, ime = 21, kms = 1, kme = 12, jms = -2, jme = 19
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: fqx, fqy, fqz, fqxl, fqyl, fqzl, field_old, ph_low, flux_out
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: ax, ay, az, bx, by, bz, cx, cy, cz, scl, ph2, fo2
   LOGICAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: lim
   REAL, DIMENSION(ims:ime, jms:jme) :: mub, mu_old, msftx, msfty
   REAL, DIMENSION(kms:kme) :: c1, c2, rdzw
   REAL :: rdx, rdy, dt, eps, r
   INTEGER :: ncase, icase, nbad, i_start, i_end, j_start, j_end, kts, ktf, nargs, nlim
   INTEGER(8) :: nlim_total
   CHARACTER(LEN=16) :: arg, allow
   LOGICAL :: on_host

   ! where do target regions run?  (must be the GPU unless ALLOW_HOST=1)
   on_host = .TRUE.
!$omp target map(from: on_host)
   on_host = omp_is_initial_device()
!$omp end target
   CALL GET_ENVIRONMENT_VARIABLE('ALLOW_HOST', allow)
   IF (on_host) THEN
      IF (TRIM(allow) /= '1') THEN
         PRINT '(a)', 'FAIL  T-PDLIM: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
         STOP 2
      END IF
      PRINT '(a)', 'note: target regions run on the host (ALLOW_HOST=1)'
   ELSE
      PRINT '(a)', 'note: target regions run on the GPU'
   END IF

   ncase = 200
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) ncase
   END IF
   CALL RANDOM_SEED()
   nbad = 0
   nlim_total = 0
   DO icase = 1, ncase
      CALL rnd3(fqx, 2.0); CALL rnd3(fqy, 2.0); CALL rnd3(fqz, 2.0)
      CALL rnd3(fqxl, 0.1); CALL rnd3(fqyl, 0.1); CALL rnd3(fqzl, 0.1)
      CALL rnd3(field_old, 1.0)
      field_old = ABS(field_old)*MOD(icase, 3)          ! some cases with zero mass: many limited cells
      CALL RANDOM_NUMBER(mub); CALL RANDOM_NUMBER(mu_old); CALL RANDOM_NUMBER(msftx); CALL RANDOM_NUMBER(msfty)
      mub = 900. + 100.*mub; mu_old = 50.*mu_old; msftx = 0.9 + 0.2*msftx; msfty = 0.9 + 0.2*msfty
      CALL RANDOM_NUMBER(c1); CALL RANDOM_NUMBER(c2); CALL RANDOM_NUMBER(rdzw)
      c2 = 100.*c2; rdzw = 0.01 + 0.1*rdzw
      CALL RANDOM_NUMBER(r); rdx = 1./(100. + 900.*r)
      CALL RANDOM_NUMBER(r); rdy = 1./(100. + 900.*r)
      dt = 1./3.
      eps = 1.e-20
      ! special values in some fluxes: zeros, -0.0, NaN
      IF (MOD(icase, 4) == 0) THEN
         fqx(5, 3, 4) = 0.; fqy(6, 4, 5) = -0.; fqz(7, 5, 6) = 0.
         fqx(8, 2, 3) = IEEE_VALUE(1.0, IEEE_QUIET_NAN)
      END IF
      ! random sub-ranges, including ranges that touch the memory bounds - 1
      CALL RANDOM_NUMBER(r); i_start = 0 + INT(r*3); CALL RANDOM_NUMBER(r); i_end = 15 + INT(r*4)
      CALL RANDOM_NUMBER(r); j_start = 0 + INT(r*3); CALL RANDOM_NUMBER(r); j_end = 13 + INT(r*4)
      kts = 1; ktf = kme - 2

      ax = fqx; ay = fqy; az = fqz
      CALL pdlim_original(ax, ay, az, fqxl, fqyl, fqzl, field_old, mub, mu_old, c1, c2, msftx, msfty, rdzw, &
                          rdx, rdy, dt, eps, ph_low, flux_out, ims, ime, kms, kme, jms, jme, &
                          i_start, i_end, j_start, j_end, kts, ktf)
      nlim = COUNT(flux_out(i_start:i_end, kts:ktf, j_start:j_end) > ph_low(i_start:i_end, kts:ktf, j_start:j_end))
      nlim_total = nlim_total + nlim
      bx = fqx; by = fqy; bz = fqz
      CALL pdlim_split(bx, by, bz, fqxl, fqyl, fqzl, field_old, mub, mu_old, c1, c2, msftx, msfty, rdzw, &
                       rdx, rdy, dt, eps, ph2, fo2, scl, lim, ims, ime, kms, kme, jms, jme, &
                       i_start, i_end, j_start, j_end, kts, ktf, .FALSE.)
      nbad = nbad + ndiff(ax, bx) + ndiff(ay, by) + ndiff(az, bz)
      cx = fqx; cy = fqy; cz = fqz
      CALL pdlim_split(cx, cy, cz, fqxl, fqyl, fqzl, field_old, mub, mu_old, c1, c2, msftx, msfty, rdzw, &
                       rdx, rdy, dt, eps, ph2, fo2, scl, lim, ims, ime, kms, kme, jms, jme, &
                       i_start, i_end, j_start, j_end, kts, ktf, .TRUE.)
      nbad = nbad + ndiff(ax, cx) + ndiff(ay, cy) + ndiff(az, cz)
   END DO
   PRINT '(a,i0,a,i0,a)', 'T-PDLIM: ', ncase, ' cases, ', nlim_total, ' limited cells'
   IF (nbad == 0) THEN
      PRINT '(a)', 'PASS  T-PDLIM (original vs split on host and in target regions: bit-identical fluxes)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-PDLIM: ', nbad, ' differing flux values'
      STOP 1
   END IF

CONTAINS

   SUBROUTINE rnd3(a, amp)
      REAL, INTENT(OUT) :: a(:,:,:)
      REAL, INTENT(IN) :: amp
      CALL RANDOM_NUMBER(a)
      a = amp*(2.*a - 1.)
   END SUBROUTINE rnd3

   INTEGER FUNCTION ndiff(a, b)
      REAL, INTENT(IN) :: a(:,:,:), b(:,:,:)
      ndiff = COUNT(TRANSFER(a, 1, SIZE(a)) /= TRANSFER(b, 1, SIZE(b)))
   END FUNCTION ndiff

END PROGRAM t_pdlim
