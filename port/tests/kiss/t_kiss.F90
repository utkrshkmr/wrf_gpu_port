! T-KISS (plan.md 8.5, P0.9a item 9): the KISS random number generator of
! RRTMG LW (kissvec, WRF/phys/module_ra_rrtmg_lw.F, module mcica_subcol_gen_lw)
! must produce the same streams on the host and on the device.
!
! kissvec relies on 32-bit signed integer wraparound (69069*seed1 + ...,
! 18000*iand(...) + ...), which the Fortran standard does not define.  A
! compiler may optimize it differently on the host and on the device.  This
! test runs the routine exactly as WRF does:
!   host:   the original vector call over all columns (ncol = N)
!   device: one thread per column calling kissvec on 1-element sections, as
!           the per-column RRTMG kernel (K-RRTMG-COL) will
! Seeds are made from pressure-like values with the source's expression
! (seed = (pmid - int(pmid)) * 1000000000), followed by 150 warm-up calls
! (changeSeed) and 64 draws per column.  Seeds and random numbers are
! compared bit for bit.  If this test fails, P0.9a item 9 applies: rewrite
! kissvec with explicit IAND-masked 32-bit arithmetic on INTEGER(8), in both
! builds (a shared refactor, T-SHARED on the CPU side).
!
! Usage: t_kiss [ncol]  (default 1000000).  ALLOW_HOST=1 for a host-only run.

MODULE kiss_mod
   IMPLICIT NONE
   INTEGER, PARAMETER :: rb = KIND(1.0), im = KIND(1)
CONTAINS
! ---- verbatim copy of WRF v4.6.0 kissvec (module_ra_rrtmg_lw.F:2699-2731) ----
! BEGIN VERBATIM WRF/phys/module_ra_rrtmg_lw.F
      subroutine kissvec(seed1,seed2,seed3,seed4,ran_arr)
!$omp declare target
      real(kind=rb), dimension(:), intent(inout)  :: ran_arr
      integer(kind=im), dimension(:), intent(inout) :: seed1,seed2,seed3,seed4
      integer(kind=im) :: i,sz,kiss
      integer(kind=im) :: m, k, n

! inline function 
      m(k, n) = ieor (k, ishft (k, n) )

      sz = size(ran_arr)
      do i = 1, sz
         seed1(i) = 69069_im * seed1(i) + 1327217885_im
         seed2(i) = m (m (m (seed2(i), 13_im), - 17_im), 5_im)
         seed3(i) = 18000_im * iand (seed3(i), 65535_im) + ishft (seed3(i), - 16_im)
         seed4(i) = 30903_im * iand (seed4(i), 65535_im) + ishft (seed4(i), - 16_im)
         kiss = seed1(i) + seed2(i) + ishft (seed3(i), 16_im) + seed4(i)
         ran_arr(i) = kiss*2.328306e-10_rb + 0.5_rb
      end do
    
      end subroutine kissvec
! END VERBATIM
END MODULE kiss_mod

PROGRAM t_kiss
   USE kiss_mod
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: nwarm = 150, ndraw = 64
   INTEGER :: ncol, i, n, nargs, nbad
   REAL(rb), ALLOCATABLE :: pmid(:,:), rh(:,:), rd(:,:), r(:), rs(:)
   INTEGER(im), ALLOCATABLE :: s1(:), s2(:), s3(:), s4(:), d1(:), d2(:), d3(:), d4(:)
   INTEGER(im) :: t1(1), t2(1), t3(1), t4(1)
   REAL(rb) :: rr(1)
   CHARACTER(LEN=16) :: arg, allow
   LOGICAL :: on_host

   ncol = 1000000
   nargs = COMMAND_ARGUMENT_COUNT()
   IF (nargs >= 1) THEN
      CALL GET_COMMAND_ARGUMENT(1, arg)
      READ (arg, *) ncol
   END IF
   on_host = .TRUE.
!$omp target map(from: on_host)
   on_host = omp_is_initial_device()
!$omp end target
   CALL GET_ENVIRONMENT_VARIABLE('ALLOW_HOST', allow)
   IF (on_host .AND. TRIM(allow) /= '1') THEN
      PRINT '(a)', 'FAIL  T-KISS: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
      STOP 2
   END IF
   PRINT '(a,a)', 'note: target regions run on the ', MERGE('host', 'GPU ', on_host)

   ALLOCATE (pmid(ncol, 4), rh(ncol, ndraw), rd(ncol, ndraw), r(ncol), rs(ncol))
   ALLOCATE (s1(ncol), s2(ncol), s3(ncol), s4(ncol), d1(ncol), d2(ncol), d3(ncol), d4(ncol))
   CALL RANDOM_SEED()
   CALL RANDOM_NUMBER(pmid)
   ! bottom four layers, decreasing pressure (Pa), 5e4 .. 1.05e5
   pmid(:,1) = 1.05e5 - 5.0e4*pmid(:,1)*0.25
   DO n = 2, 4
      pmid(:,n) = pmid(:,n-1) - 10. - 2000.*pmid(:,n)
   END DO
   ! a few special seeds: zero fraction, largest fraction
   pmid(1,:) = 100000.
   IF (ncol > 1) pmid(2,1) = NEAREST(100001., -1.)

   ! seeds exactly as in generate_stochastic_clouds (module_ra_rrtmg_lw.F:2429-2432)
   DO i = 1, ncol
      s1(i) = (pmid(i,1) - int(pmid(i,1)))  * 1000000000_im
      s2(i) = (pmid(i,2) - int(pmid(i,2)))  * 1000000000_im
      s3(i) = (pmid(i,3) - int(pmid(i,3)))  * 1000000000_im
      s4(i) = (pmid(i,4) - int(pmid(i,4)))  * 1000000000_im
   END DO
   ! device: seeds computed in the kernel from the same pmid
!$omp target teams distribute parallel do map(to: pmid) map(from: d1, d2, d3, d4)
   DO i = 1, ncol
      d1(i) = (pmid(i,1) - int(pmid(i,1)))  * 1000000000_im
      d2(i) = (pmid(i,2) - int(pmid(i,2)))  * 1000000000_im
      d3(i) = (pmid(i,3) - int(pmid(i,3)))  * 1000000000_im
      d4(i) = (pmid(i,4) - int(pmid(i,4)))  * 1000000000_im
   END DO
   nbad = COUNT(s1 /= d1) + COUNT(s2 /= d2) + COUNT(s3 /= d3) + COUNT(s4 /= d4)
   IF (nbad > 0) PRINT '(a,i0)', 'seed expression differs host/device: ', nbad

   ! host: the original vector calls
   DO n = 1, nwarm
      CALL kissvec(s1, s2, s3, s4, r)
   END DO
   DO n = 1, ndraw
      CALL kissvec(s1, s2, s3, s4, r)
      rh(:,n) = r
   END DO

   ! device: one thread per column, 1-element sections
!$omp target teams distribute parallel do map(tofrom: d1, d2, d3, d4) map(from: rd) private(n, t1, t2, t3, t4, rr)
   DO i = 1, ncol
      t1(1) = d1(i); t2(1) = d2(i); t3(1) = d3(i); t4(1) = d4(i)
      DO n = 1, nwarm
         CALL kissvec(t1, t2, t3, t4, rr)
      END DO
      DO n = 1, ndraw
         CALL kissvec(t1, t2, t3, t4, rr)
         rd(i,n) = rr(1)
      END DO
      d1(i) = t1(1); d2(i) = t2(1); d3(i) = t3(1); d4(i) = t4(1)
   END DO
   nbad = nbad + COUNT(s1 /= d1) + COUNT(s2 /= d2) + COUNT(s3 /= d3) + COUNT(s4 /= d4)
   nbad = nbad + COUNT(TRANSFER(rh, 1, SIZE(rh)) /= TRANSFER(rd, 1, SIZE(rd)))
   PRINT '(a,i0,a,i0,a)', 'T-KISS: ', ncol, ' columns, ', ncol*(nwarm+ndraw), ' kissvec steps'
   IF (nbad == 0) THEN
      PRINT '(a)', 'PASS  T-KISS (host vector calls vs device per-column calls: identical seeds and numbers)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-KISS: ', nbad, ' differing values (see P0.9a item 9)'
      STOP 1
   END IF
END PROGRAM t_kiss
