! Template CP (plan.md 8.0 CP-1..CP-4; port/agent/PHASE3.md): a column-physics
! scheme in the form of WSM6 / YSU (wrapper in phys/module_*.F, core in
! phys/physics_mmm/<scheme>.F90) ported to one GPU thread per column.
!
! The scheme here is small and synthetic, but it has every construct that
! makes the real ones hard:
!   wrapper  per-j slabs (its:ite,kts:kte) gathered with expressions
!            (t = th*pii), surface accumulators (rainnc), an error flag that
!            the source turns into wrf_error_fatal, scatter (th = t/pii);
!   core     assumed-shape dummies dimension(its:,:) (physics_mmm style),
!            automatic arrays (its:ite,kts:kte) and (its:ite), a statement
!            function, module SAVE constants set by an init routine, a
!            whole-array statement, a downward recurrence (sedimentation), a
!            column sum in k order, errmsg/errflg.
!
! GPU form (the rules of PHASE3.md "How a column scheme is ported"):
!   CP-1  one kernel over (j,i) replaces the j-slab loop; each thread gathers
!         its column into PRIVATE fixed-size arrays with the wrapper own
!         expressions, calls the core, scatters with the wrapper expressions;
!         accumulators are 1-element private arrays written back.
!   CP-2  the core is called with its=ite=1, kts=1, kte=nz and receives the
!         SECTIONS x_col(1:1,1:nz), so its assumed-shape dummies have the
!         active size.
!   CP-3  automatic arrays of the core get fixed bounds (WRF/inc/gpu_col.h:
!         GPU_IK, GPU_I); each declaration is written twice, the original one
!         in the #else branch; whole-array statements on them become explicit
!         sections (its:ite,kts:kte).
!   CP-4  the core is declare target; errmsg becomes an integer code; the
!         error count is reduced and reported on the host; module SAVE
!         constants are declare target and updated after the init.
! The test compares th, qv, qr, rainnc, rainncv bit for bit and whether an
! error was raised (the source stops the run on any error: per slab there,
! per column here), original vs GPU form on the host and on the device, for
! several tiles; the data make some calls raise an error and others not.  Usage: t_tmpl_cp [nrep]; ALLOW_HOST=1 for host-only.
! TMPL_NO_STMTFN: the statement function as a module function (probe F-STMTFN).

#include "gpu_col.h"

MODULE tcp_const
   ! like the SAVE constants of mp_wsm6 (physics_mmm/mp_wsm6.F90:46-64)
   IMPLICIT NONE
   REAL, SAVE :: pvtr, xl, rv, denr, qmax
!$omp declare target(pvtr, xl, rv, denr, qmax)
CONTAINS
   SUBROUTINE tcp_init(den0)
      REAL, INTENT(IN) :: den0
      pvtr = 0.25*SQRT(den0/1.28)
      xl = 2.5e6
      rv = 461.6
      denr = 1000.
      qmax = 0.004
   END SUBROUTINE tcp_init
END MODULE tcp_const

MODULE tcp_mod
   USE tcp_const
   IMPLICIT NONE
CONTAINS

!======================================================================
! ORIGINAL (what CPU-REF compiles): core and slab wrapper
!======================================================================
   subroutine tcp_run(t, q, qr, p, delz, rain, rainncv, dtcld, its, ite, kts, kte, errmsg, errflg)
      implicit none
      integer, intent(in) :: its, ite, kts, kte
      real, intent(in) :: dtcld
      real, dimension(its:, :), intent(inout) :: t, q, qr
      real, dimension(its:, :), intent(in) :: p, delz
      real, dimension(its:), intent(inout) :: rain, rainncv
      character(len=*), intent(out) :: errmsg
      integer, intent(out) :: errflg
      real, dimension(its:ite, kts:kte) :: qs, work, falk, rh
      real, dimension(its:ite) :: colsum
      real :: es, cpm
      integer :: i, k
      real :: cpmcal, a
      cpmcal(a) = 1004.5*(1. - a) + 1846.4*a

      errmsg = ' '
      errflg = 0
      work = 0.
      rh(:, :) = q(:, :)
      do k = kts, kte
         do i = its, ite
            es = 611.2 + 0.5*(t(i, k) - 200.)*(t(i, k) - 200.)
            qs(i, k) = 0.622*es/(p(i, k) - es)
            work(i, k) = max(q(i, k) - qs(i, k), 0.)/(1. + xl*xl*qs(i, k)/(cpmcal(q(i, k))*rv*t(i, k)*t(i, k)))
            q(i, k) = q(i, k) - work(i, k)
            qr(i, k) = qr(i, k) + work(i, k)
            cpm = cpmcal(rh(i, k))
            t(i, k) = t(i, k) + xl/cpm*work(i, k)
         end do
      end do
      ! sedimentation: downward recurrence
      do i = its, ite
         falk(i, kte) = pvtr*qr(i, kte)*sqrt(qr(i, kte))
         qr(i, kte) = max(qr(i, kte) - dtcld*falk(i, kte)/delz(i, kte), 0.)
      end do
      do k = kte - 1, kts, -1
         do i = its, ite
            qr(i, k) = max(qr(i, k) + dtcld*(falk(i, k + 1) - pvtr*qr(i, k)*sqrt(qr(i, k)))/delz(i, k), 0.)
            falk(i, k) = pvtr*qr(i, k)*sqrt(qr(i, k))
         end do
      end do
      do i = its, ite
         rainncv(i) = falk(i, kts)*dtcld/denr*1000.
         rain(i) = rain(i) + rainncv(i)
      end do
      ! column sum in k order and an error branch
      do i = its, ite
         colsum(i) = 0.
         do k = kts, kte
            colsum(i) = colsum(i) + work(i, k)*delz(i, k)
         end do
         if (colsum(i) > qmax*1000.) then
            errmsg = 'tcp_run: condensation too large'
            errflg = 1
         end if
      end do
   end subroutine tcp_run

   SUBROUTINE tcp_wrap(th, qv, qr, pii, p, dz8w, rainnc, rainncv, dt, nerr, &
                       ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte)
      IMPLICIT NONE
      INTEGER, INTENT(IN) :: ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: th, qv, qr
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: pii, p, dz8w
      REAL, DIMENSION(ims:ime, jms:jme), INTENT(INOUT) :: rainnc, rainncv
      REAL, INTENT(IN) :: dt
      INTEGER, INTENT(OUT) :: nerr
      REAL, DIMENSION(its:ite, kts:kte) :: t, q, qrs, pp, dz
      REAL, DIMENSION(its:ite) :: rn, rncv
      CHARACTER(LEN=256) :: errmsg
      INTEGER :: errflg, i, j, k
      nerr = 0
      DO j = jts, jte
         DO k = kts, kte
            DO i = its, ite
               t(i, k) = th(i, k, j)*pii(i, k, j)
               q(i, k) = qv(i, k, j)
               qrs(i, k) = qr(i, k, j)
               pp(i, k) = p(i, k, j)
               dz(i, k) = dz8w(i, k, j)
            END DO
         END DO
         DO i = its, ite
            rn(i) = rainnc(i, j)
            rncv(i) = rainncv(i, j)
         END DO
         CALL tcp_run(t, q, qrs, pp, dz, rn, rncv, dt, its, ite, kts, kte, errmsg, errflg)
         IF (errflg /= 0) nerr = nerr + 1     ! WRF: CALL wrf_error_fatal(errmsg)
         DO k = kts, kte
            DO i = its, ite
               th(i, k, j) = t(i, k)/pii(i, k, j)
               qv(i, k, j) = q(i, k)
               qr(i, k, j) = qrs(i, k)
            END DO
         END DO
         DO i = its, ite
            rainnc(i, j) = rn(i)
            rainncv(i, j) = rncv(i)
         END DO
      END DO
   END SUBROUTINE tcp_wrap

!======================================================================
! GPU FORM (what WRF_GPU compiles; in WRF the same file holds both, the
! declarations under #ifdef WRF_GPU / #else / #endif)
!======================================================================
#ifdef TMPL_NO_STMTFN
   REAL FUNCTION cpmcal_f(a)
!$omp declare target
      REAL, INTENT(IN) :: a
      cpmcal_f = 1004.5*(1. - a) + 1846.4*a
   END FUNCTION cpmcal_f
#endif

   subroutine tcp_run_gpu(t, q, qr, p, delz, rain, rainncv, dtcld, its, ite, kts, kte, errflg)
!$omp declare target
      implicit none
      integer, intent(in) :: its, ite, kts, kte
      real, intent(in) :: dtcld
      real, dimension(its:, :), intent(inout) :: t, q, qr
      real, dimension(its:, :), intent(in) :: p, delz
      real, dimension(its:), intent(inout) :: rain, rainncv
      integer, intent(out) :: errflg
      ! CP-3: was dimension(its:ite, kts:kte) and dimension(its:ite)
      real, dimension(GPU_IK) :: qs, work, falk, rh
      real, dimension(GPU_I) :: colsum
      real :: es, cpm
      integer :: i, k
#ifndef TMPL_NO_STMTFN
      real :: cpmcal, a
      cpmcal(a) = 1004.5*(1. - a) + 1846.4*a
#else
#define cpmcal cpmcal_f
#endif

      ! CP-4: errmsg = ' ' dropped (integer code only)
      errflg = 0
      ! CP-3: whole-array statements on the fixed-size arrays become explicit sections
      work(its:ite, kts:kte) = 0.
      rh(its:ite, kts:kte) = q(its:ite, kts:kte)
      do k = kts, kte
         do i = its, ite
            es = 611.2 + 0.5*(t(i, k) - 200.)*(t(i, k) - 200.)
            qs(i, k) = 0.622*es/(p(i, k) - es)
            work(i, k) = max(q(i, k) - qs(i, k), 0.)/(1. + xl*xl*qs(i, k)/(cpmcal(q(i, k))*rv*t(i, k)*t(i, k)))
            q(i, k) = q(i, k) - work(i, k)
            qr(i, k) = qr(i, k) + work(i, k)
            cpm = cpmcal(rh(i, k))
            t(i, k) = t(i, k) + xl/cpm*work(i, k)
         end do
      end do
      do i = its, ite
         falk(i, kte) = pvtr*qr(i, kte)*sqrt(qr(i, kte))
         qr(i, kte) = max(qr(i, kte) - dtcld*falk(i, kte)/delz(i, kte), 0.)
      end do
      do k = kte - 1, kts, -1
         do i = its, ite
            qr(i, k) = max(qr(i, k) + dtcld*(falk(i, k + 1) - pvtr*qr(i, k)*sqrt(qr(i, k)))/delz(i, k), 0.)
            falk(i, k) = pvtr*qr(i, k)*sqrt(qr(i, k))
         end do
      end do
      do i = its, ite
         rainncv(i) = falk(i, kts)*dtcld/denr*1000.
         rain(i) = rain(i) + rainncv(i)
      end do
      do i = its, ite
         colsum(i) = 0.
         do k = kts, kte
            colsum(i) = colsum(i) + work(i, k)*delz(i, k)
         end do
         if (colsum(i) > qmax*1000.) then
            errflg = 1              ! CP-4: was errmsg = 'tcp_run: condensation too large'; errflg = 1
         end if
      end do
#ifdef TMPL_NO_STMTFN
#undef cpmcal
#endif
   end subroutine tcp_run_gpu

   SUBROUTINE tcp_wrap_gpu(th, qv, qr, pii, p, dz8w, rainnc, rainncv, dt, nerr, dev, &
                           ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte)
      IMPLICIT NONE
      INTEGER, INTENT(IN) :: ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(INOUT) :: th, qv, qr
      REAL, DIMENSION(ims:ime, kms:kme, jms:jme), INTENT(IN) :: pii, p, dz8w
      REAL, DIMENSION(ims:ime, jms:jme), INTENT(INOUT) :: rainnc, rainncv
      REAL, INTENT(IN) :: dt
      INTEGER, INTENT(OUT) :: nerr
      LOGICAL, INTENT(IN) :: dev
      ! CP-1: private fixed-size columns (were the slabs (its:ite,kts:kte) and (its:ite))
      REAL, DIMENSION(GPU_IK) :: t, q, qrs, pp, dz
      REAL, DIMENSION(GPU_I) :: rn, rncv
      INTEGER :: errflg, i, j, k, kk, nz
      nz = kte - kts + 1
      nerr = 0
!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) &
!$omp& shared(th, qv, qr, pii, p, dz8w, rainnc, rainncv) &
!$omp& firstprivate(its, ite, jts, jte, kts, kte, nz, dt) &
!$omp& private(k, kk, t, q, qrs, pp, dz, rn, rncv, errflg) reduction(+: nerr)
      DO j = jts, jte
      DO i = its, ite
         DO k = kts, kte
            kk = k - kts + 1
            t(1, kk) = th(i, k, j)*pii(i, k, j)
            q(1, kk) = qv(i, k, j)
            qrs(1, kk) = qr(i, k, j)
            pp(1, kk) = p(i, k, j)
            dz(1, kk) = dz8w(i, k, j)
         END DO
         rn(1) = rainnc(i, j)
         rncv(1) = rainncv(i, j)
         ! CP-2: one column, its=ite=1, kts=1, kte=nz, sections with the active size
         CALL tcp_run_gpu(t(1:1, 1:nz), q(1:1, 1:nz), qrs(1:1, 1:nz), pp(1:1, 1:nz), dz(1:1, 1:nz), &
                          rn(1:1), rncv(1:1), dt, 1, 1, 1, nz, errflg)
         IF (errflg /= 0) nerr = nerr + 1   ! host: IF (nerr > 0) CALL wrf_error_fatal('tcp_run: ...')
         DO k = kts, kte
            kk = k - kts + 1
            th(i, k, j) = t(1, kk)/pii(i, k, j)
            qv(i, k, j) = q(1, kk)
            qr(i, k, j) = qrs(1, kk)
         END DO
         rainnc(i, j) = rn(1)
         rainncv(i, j) = rncv(1)
      END DO
      END DO
   END SUBROUTINE tcp_wrap_gpu
END MODULE tcp_mod


PROGRAM t_tmpl_cp
   USE tcp_mod
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: ims = -4, ime = 29, jms = -4, jme = 25, kms = 1, kme = 41
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: th0, qv0, qr0, pii, p, dz8w
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: tha, qva, qra, thb, qvb, qrb, thc, qvc, qrc
   REAL, DIMENSION(ims:ime, jms:jme) :: rn0, rnv0, rna, rnva, rnb, rnvb, rnc, rnvc
   INTEGER :: irep, nrep, nbad, it, nargs, tiles(6, 4), nea, neb, nec, ncall_err, ncall_ok
   CHARACTER(LEN=16) :: arg, allow
   LOGICAL :: on_host
   REAL :: dt
   ! (its, ite, jts, jte, kts, kte): whole patch, interior tile, east-north edge, few levels
   tiles(:,1) = (/ 1, 24, 1, 20, 1, 40 /)
   tiles(:,2) = (/ 5, 17, 4, 13, 1, 40 /)
   tiles(:,3) = (/ 13, 24, 11, 20, 1, 40 /)
   tiles(:,4) = (/ 1, 24, 1, 20, 1, 7 /)
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
      PRINT '(a)', 'FAIL  T-TMPL-CP: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
      STOP 2
   END IF
   PRINT '(a,a)', 'note: target regions run on the ', MERGE('host', 'GPU ', on_host)
   CALL tcp_init(1.28)
!$omp target update to(pvtr, xl, rv, denr, qmax)
   CALL RANDOM_SEED()
   nbad = 0
   ncall_err = 0
   ncall_ok = 0
   dt = 3.
   DO irep = 1, nrep
      CALL RANDOM_NUMBER(th0); th0 = 280. + 30.*th0
      CALL RANDOM_NUMBER(pii); pii = 0.8 + 0.2*pii
      CALL RANDOM_NUMBER(qv0); qv0 = 0.02*qv0
      CALL RANDOM_NUMBER(qr0); qr0 = 0.003*qr0
      CALL RANDOM_NUMBER(p); p = 50000. + 50000.*p
      CALL RANDOM_NUMBER(dz8w); dz8w = 20. + 400.*dz8w
      CALL RANDOM_NUMBER(rn0); rn0 = 10.*rn0
      CALL RANDOM_NUMBER(rnv0)
      DO it = 1, 4
         tha = th0; qva = qv0; qra = qr0; rna = rn0; rnva = rnv0
         thb = th0; qvb = qv0; qrb = qr0; rnb = rn0; rnvb = rnv0
         thc = th0; qvc = qv0; qrc = qr0; rnc = rn0; rnvc = rnv0
         CALL tcp_wrap(tha, qva, qra, pii, p, dz8w, rna, rnva, dt, nea, ims, ime, jms, jme, kms, kme, &
                       tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), tiles(5,it), tiles(6,it))
         CALL tcp_wrap_gpu(thb, qvb, qrb, pii, p, dz8w, rnb, rnvb, dt, neb, .FALSE., ims, ime, jms, jme, kms, kme, &
                           tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), tiles(5,it), tiles(6,it))
!$omp target data map(to: pii, p, dz8w) map(tofrom: thc, qvc, qrc, rnc, rnvc)
         CALL tcp_wrap_gpu(thc, qvc, qrc, pii, p, dz8w, rnc, rnvc, dt, nec, .TRUE., ims, ime, jms, jme, kms, kme, &
                           tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), tiles(5,it), tiles(6,it))
!$omp end target data
         nbad = nbad + ndiff3(tha, thb) + ndiff3(tha, thc) + ndiff3(qva, qvb) + ndiff3(qva, qvc) &
                     + ndiff3(qra, qrb) + ndiff3(qra, qrc) + ndiff2(rna, rnb) + ndiff2(rna, rnc) &
                     + ndiff2(rnva, rnvb) + ndiff2(rnva, rnvc)
         IF (((neb > 0) .NEQV. (nea > 0)) .OR. ((nec > 0) .NEQV. (nea > 0))) nbad = nbad + 1
         IF (nea > 0) THEN
            ncall_err = ncall_err + 1
         ELSE
            ncall_ok = ncall_ok + 1
         END IF
      END DO
   END DO
   PRINT '(a,i0,a,i0,a,i0,a)', 'T-TMPL-CP: ', nrep, ' random states x 4 tiles; ', ncall_err, &
      ' calls raised the error, ', ncall_ok, ' did not'
   IF (ncall_err == 0 .OR. ncall_ok == 0) THEN
      PRINT '(a)', 'FAIL  T-TMPL-CP: the error branch is taken in all or no calls (test data too weak)'
      STOP 1
   END IF
   IF (nbad == 0) THEN
      PRINT '(a)', 'PASS  T-TMPL-CP (slab wrapper + core vs column kernel: bit-identical state, accumulators, errors)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-TMPL-CP: ', nbad, ' differing values or error results'
      STOP 1
   END IF
CONTAINS
   INTEGER FUNCTION ndiff3(a, b)
      REAL, INTENT(IN) :: a(:,:,:), b(:,:,:)
      ndiff3 = COUNT(TRANSFER(a, 1, SIZE(a)) /= TRANSFER(b, 1, SIZE(b)))
   END FUNCTION ndiff3
   INTEGER FUNCTION ndiff2(a, b)
      REAL, INTENT(IN) :: a(:,:), b(:,:)
      ndiff2 = COUNT(TRANSFER(a, 1, SIZE(a)) /= TRANSFER(b, 1, SIZE(b)))
   END FUNCTION ndiff2
END PROGRAM t_tmpl_cp
