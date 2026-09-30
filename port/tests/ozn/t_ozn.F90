! T-OZN (plan.md 8.5, kernel K-OZP): ozone interpolation to model levels.
!
! ozn_p_int (WRF/phys/module_radiation_driver.F, d01 only, every radiation
! call) searches the ozone levels for all columns of a j-row together: the
! search start kkstart is the minimum of kupper(i) over the row, and the
! search stops early when every column of the row has found its level
! (GOTO 35).  A column's result can therefore depend on the other columns of
! its row (non-monotone pressure, a level exactly at pin(1)).
!
! The GPU version keeps this exactly: one thread per j-row (K-OZP), the row's
! loops over i unchanged inside the thread.  pmid(its:ite,kts:kte) and
! kupper(its:ite) become work arrays with a j index, the GOTO 35 becomes a
! flag and EXIT, wrf_error_fatal becomes an error flag checked on the host.
! Use ozn_p_int_gpu below as the reference for K-OZP.  (plan.md first
! proposed a per-column rewrite; that is only equal for monotone profiles,
! so it is not used.)
!
! The test compares the original (verbatim copy, checked against the source
! by port/tools/check_verbatim.py) with ozn_p_int_gpu on the host and in a
! target region, bit for bit, on realistic columns plus the edge cases:
! a level exactly at an ozone level, a level at pin(1), levels above pin(1)
! and below pin(levsiz), a non-monotone column.
! Usage: t_ozn [nrep]   ALLOW_HOST=1 for a host-only run.

MODULE ozn_mod
   IMPLICIT NONE
CONTAINS
   SUBROUTINE wrf_error_fatal(msg)
      CHARACTER(LEN=*), INTENT(IN) :: msg
      PRINT '(a)', 'wrf_error_fatal: '//msg
      STOP 3
   END SUBROUTINE wrf_error_fatal

! BEGIN VERBATIM WRF/phys/module_radiation_driver.F
SUBROUTINE ozn_p_int(p ,pin, levsiz, ozmixt, o3vmr, &
                              ids , ide , jds , jde , kds , kde ,     &
                              ims , ime , jms , jme , kms , kme ,     &
                              its , ite , jts , jte , kts , kte )

!-----------------------------------------------------------------------
!
! Purpose: Interpolate ozone from current time-interpolated values to model levels
!
! Method: Use pressure values to determine interpolation levels
!
! Author: Bruce Briegleb
! WW: Adapted for general use
!
!--------------------------------------------------------------------------
   implicit none
!--------------------------------------------------------------------------
!
! Arguments
!
   INTEGER,    INTENT(IN) ::           ids,ide, jds,jde, kds,kde, &
                                       ims,ime, jms,jme, kms,kme, &
                                       its,ite, jts,jte, kts,kte

   integer, intent(in) :: levsiz              ! number of ozone layers

   real, intent(in) :: p(ims:ime,kms:kme,jms:jme)   ! level pressures (mks, bottom-up)
   real, intent(in) :: pin(levsiz)        ! ozone data level pressures (mks, top-down)
   real, intent(in) :: ozmixt(ims:ime,levsiz,jms:jme) ! ozone mixing ratio

   real, intent(out) :: o3vmr(ims:ime,kms:kme,jms:jme) ! ozone volume mixing ratio
!
! local storage
!
   real    pmid(its:ite,kts:kte)
   integer i,j                 ! longitude index
   integer k, kk, kkstart, kout! level indices
   integer kupper(its:ite)     ! Level indices for interpolation
   integer kount               ! Counter
   integer ncol, pver

   real    dpu                 ! upper level pressure difference
   real    dpl                 ! lower level pressure difference

   ncol = ite - its + 1
   pver = kte - kts + 1

   do j=jts,jte
!
! Initialize index array
!
!  do i=1, ncol
   do i=its, ite
      kupper(i) = 1
   end do
!
! Reverse the pressure array, and pin is in Pa, the same as model pmid
!
      do k = kts,kte
         kk = kte - k + kts
      do i = its,ite
         pmid(i,kk) = p(i,k,j)
      enddo
      enddo

   do k=1,pver

      kout = pver - k + 1
!     kout = k
!
! Top level we need to start looking is the top level for the previous k
! for all longitude points
!
      kkstart = levsiz
!     do i=1,ncol
      do i=its,ite
         kkstart = min0(kkstart,kupper(i))
      end do
      kount = 0
!
! Store level indices for interpolation
!
      do kk=kkstart,levsiz-1
!        do i=1,ncol
         do i=its,ite
            if (pin(kk).lt.pmid(i,k) .and. pmid(i,k).le.pin(kk+1)) then
               kupper(i) = kk
               kount = kount + 1
            end if
         end do
!
! If all indices for this level have been found, do the interpolation and
! go to the next level
!
         if (kount.eq.ncol) then
!           do i=1,ncol
            do i=its,ite
               dpu = pmid(i,k) - pin(kupper(i))
               dpl = pin(kupper(i)+1) - pmid(i,k)
               o3vmr(i,kout,j) = (ozmixt(i,kupper(i),j)*dpl + &
                             ozmixt(i,kupper(i)+1,j)*dpu)/(dpl + dpu)
            end do
            goto 35
         end if
      end do
!
! If we've fallen through the kk=1,levsiz-1 loop, we cannot interpolate and
! must extrapolate from the bottom or top ozone data level for at least some
! of the longitude points.
!
!     do i=1,ncol
      do i=its,ite
         if (pmid(i,k) .lt. pin(1)) then
            o3vmr(i,kout,j) = ozmixt(i,1,j)*pmid(i,k)/pin(1)
         else if (pmid(i,k) .gt. pin(levsiz)) then
            o3vmr(i,kout,j) = ozmixt(i,levsiz,j)
         else
            dpu = pmid(i,k) - pin(kupper(i))
            dpl = pin(kupper(i)+1) - pmid(i,k)
            o3vmr(i,kout,j) = (ozmixt(i,kupper(i),j)*dpl + &
                          ozmixt(i,kupper(i)+1,j)*dpu)/(dpl + dpu)
         end if
      end do

      if (kount.gt.ncol) then
!        call endrun ('OZN_P_INT: Bad ozone data: non-monotonicity suspected')
         call wrf_error_fatal ('OZN_P_INT: Bad ozone data: non-monotonicity suspected')
      end if
35    continue

   end do
   end do

   return
END SUBROUTINE ozn_p_int
! END VERBATIM

! ---- reference GPU version (K-OZP): one thread per j-row ----
SUBROUTINE ozn_p_int_gpu(p ,pin, levsiz, ozmixt, o3vmr, pmid_w, kupper_w, ierr, dev, &
                              ids , ide , jds , jde , kds , kde ,     &
                              ims , ime , jms , jme , kms , kme ,     &
                              its , ite , jts , jte , kts , kte )
   implicit none
   INTEGER,    INTENT(IN) ::           ids,ide, jds,jde, kds,kde, &
                                       ims,ime, jms,jme, kms,kme, &
                                       its,ite, jts,jte, kts,kte
   integer, intent(in) :: levsiz
   logical, intent(in) :: dev
   real, intent(in) :: p(ims:ime,kms:kme,jms:jme)
   real, intent(in) :: pin(levsiz)
   real, intent(in) :: ozmixt(ims:ime,levsiz,jms:jme)
   real, intent(out) :: o3vmr(ims:ime,kms:kme,jms:jme)
   real, intent(inout) :: pmid_w(ims:ime,kms:kme,jms:jme)   ! work array, was pmid(its:ite,kts:kte)
   integer, intent(inout) :: kupper_w(ims:ime,jms:jme)      ! work array, was kupper(its:ite)
   integer, intent(out) :: ierr
   integer i,j
   integer k, kk, kkstart, kout
   integer kount
   integer ncol, pver
   logical done
   real    dpu
   real    dpl

   ncol = ite - its + 1
   pver = kte - kts + 1
   ierr = 0

!$omp target teams distribute parallel do if(target: dev) default(none) &
!$omp& shared(p, pin, ozmixt, o3vmr, pmid_w, kupper_w) &
!$omp& firstprivate(its, ite, jts, jte, kts, kte, levsiz, ncol, pver) &
!$omp& private(i, k, kk, kkstart, kout, kount, done, dpu, dpl) reduction(max: ierr)
   do j=jts,jte
   do i=its, ite
      kupper_w(i,j) = 1
   end do
      do k = kts,kte
         kk = kte - k + kts
      do i = its,ite
         pmid_w(i,kk,j) = p(i,k,j)
      enddo
      enddo

   do k=1,pver

      kout = pver - k + 1
      kkstart = levsiz
      do i=its,ite
         kkstart = min0(kkstart,kupper_w(i,j))
      end do
      kount = 0
      done = .false.
      do kk=kkstart,levsiz-1
         do i=its,ite
            if (pin(kk).lt.pmid_w(i,k,j) .and. pmid_w(i,k,j).le.pin(kk+1)) then
               kupper_w(i,j) = kk
               kount = kount + 1
            end if
         end do
         if (kount.eq.ncol) then
            do i=its,ite
               dpu = pmid_w(i,k,j) - pin(kupper_w(i,j))
               dpl = pin(kupper_w(i,j)+1) - pmid_w(i,k,j)
               o3vmr(i,kout,j) = (ozmixt(i,kupper_w(i,j),j)*dpl + &
                             ozmixt(i,kupper_w(i,j)+1,j)*dpu)/(dpl + dpu)
            end do
            done = .true.
            exit
         end if
      end do
      if (.not. done) then
      do i=its,ite
         if (pmid_w(i,k,j) .lt. pin(1)) then
            o3vmr(i,kout,j) = ozmixt(i,1,j)*pmid_w(i,k,j)/pin(1)
         else if (pmid_w(i,k,j) .gt. pin(levsiz)) then
            o3vmr(i,kout,j) = ozmixt(i,levsiz,j)
         else
            dpu = pmid_w(i,k,j) - pin(kupper_w(i,j))
            dpl = pin(kupper_w(i,j)+1) - pmid_w(i,k,j)
            o3vmr(i,kout,j) = (ozmixt(i,kupper_w(i,j),j)*dpl + &
                          ozmixt(i,kupper_w(i,j)+1,j)*dpu)/(dpl + dpu)
         end if
      end do

      if (kount.gt.ncol) then
         ierr = 1
      end if
      end if

   end do
   end do
   ! on the host, after the kernel:
   ! IF (ierr > 0) CALL wrf_error_fatal ('OZN_P_INT: Bad ozone data: non-monotonicity suspected')
END SUBROUTINE ozn_p_int_gpu
END MODULE ozn_mod


PROGRAM t_ozn
   USE ozn_mod
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: levsiz = 59
   INTEGER, PARAMETER :: ids = 1, ide = 61, jds = 1, jde = 41, kds = 1, kde = 61
   INTEGER, PARAMETER :: ims = -4, ime = 66, jms = -4, jme = 46, kms = 1, kme = 61
   INTEGER, PARAMETER :: its = 1, ite = 60, jts = 1, jte = 40, kts = 1, kte = 60
   REAL :: pin(levsiz), eta(kts:kte), r, psfc, ptop
   REAL, ALLOCATABLE :: p(:,:,:), ozmixt(:,:,:), o3a(:,:,:), o3b(:,:,:), o3c(:,:,:), pmid_w(:,:,:)
   INTEGER, ALLOCATABLE :: kupper_w(:,:)
   INTEGER :: i, j, k, irep, nrep, nbad, ierr, u, ios, nargs
   CHARACTER(LEN=256) :: path, allow, arg
   LOGICAL :: on_host

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
      PRINT '(a)', 'FAIL  T-OZN: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
      STOP 2
   END IF
   PRINT '(a,a)', 'note: target regions run on the ', MERGE('host', 'GPU ', on_host)

   ! ozone levels as WRF reads them (module_ra_cam_support.F: hPa * 100.)
   CALL GET_ENVIRONMENT_VARIABLE('OZONE_PLEV', path)
   IF (LEN_TRIM(path) == 0) path = '../../../WRF/run/ozone_plev.formatted'
   OPEN (NEWUNIT=u, FILE=TRIM(path), STATUS='OLD', IOSTAT=ios)
   IF (ios /= 0) THEN
      PRINT '(a)', 'FAIL  T-OZN: cannot open '//TRIM(path)//' (set OZONE_PLEV)'
      STOP 2
   END IF
   DO k = 1, levsiz
      READ (u, *) pin(k)
   END DO
   CLOSE (u)
   DO k = 1, levsiz
      pin(k) = pin(k)*100.
   END DO

   ALLOCATE (p(ims:ime,kms:kme,jms:jme), ozmixt(ims:ime,levsiz,jms:jme), o3a(ims:ime,kms:kme,jms:jme), &
             o3b(ims:ime,kms:kme,jms:jme), o3c(ims:ime,kms:kme,jms:jme), pmid_w(ims:ime,kms:kme,jms:jme), &
             kupper_w(ims:ime,jms:jme))
   CALL RANDOM_SEED()
   nbad = 0
   DO irep = 1, nrep
      CALL RANDOM_NUMBER(ozmixt)
      ozmixt = 1.e-8 + 1.e-5*ozmixt
      DO k = kts, kte
         eta(k) = 1. - REAL(k - kts)/REAL(kte - kts)
      END DO
      eta = eta**1.3
      DO j = jts, jte
      DO i = its, ite
         CALL RANDOM_NUMBER(r); psfc = 80000. + 25000.*r
         CALL RANDOM_NUMBER(r); ptop = 5000. + 15000.*r
         IF (MOD(irep, 3) == 0) ptop = 20.       ! top levels above pin(1)
         DO k = kts, kte
            p(i,k,j) = ptop + (psfc - ptop)*eta(k)
         END DO
      END DO
      END DO
      ! edge cases, placed in a few rows only
      p(3,10,2) = pin(40)                        ! exactly at an ozone level
      p(4,kte,2) = pin(1)                        ! exactly at pin(1): found by no bracket
      p(5,kts,3) = pin(levsiz) + 500.            ! below the lowest ozone level
      p(6,20,4) = p(6,22,4); p(6,21,4) = p(6,19,4)   ! non-monotone column
      p(7,30,5) = p(7,31,5)                      ! two equal levels

      CALL ozn_p_int(p, pin, levsiz, ozmixt, o3a, ids, ide, jds, jde, kds, kde, &
                     ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte)
      o3b = o3a; o3c = o3a    ! (only its..ite, kts..kte, jts..jte are written)
      o3b(its:ite,kts:kte,jts:jte) = -1.; o3c(its:ite,kts:kte,jts:jte) = -1.
      CALL ozn_p_int_gpu(p, pin, levsiz, ozmixt, o3b, pmid_w, kupper_w, ierr, .FALSE., &
                         ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte)
      nbad = nbad + ierr
!$omp target data map(to: p, pin, ozmixt) map(tofrom: o3c) map(alloc: pmid_w, kupper_w)
      CALL ozn_p_int_gpu(p, pin, levsiz, ozmixt, o3c, pmid_w, kupper_w, ierr, .TRUE., &
                         ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte)
!$omp end target data
      nbad = nbad + ierr
      nbad = nbad + COUNT(TRANSFER(o3a, 1, SIZE(o3a)) /= TRANSFER(o3b, 1, SIZE(o3b)))
      nbad = nbad + COUNT(TRANSFER(o3a, 1, SIZE(o3a)) /= TRANSFER(o3c, 1, SIZE(o3c)))
   END DO
   PRINT '(a,i0,a,i0,a)', 'T-OZN: ', nrep, ' fields of ', (ite-its+1)*(jte-jts+1), ' columns'
   IF (nbad == 0) THEN
      PRINT '(a)', 'PASS  T-OZN (original vs row-parallel version on host and in target regions: bit-identical)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-OZN: ', nbad, ' differing values or error flags'
      STOP 1
   END IF
END PROGRAM t_ozn
