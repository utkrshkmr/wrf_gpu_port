!WRF:DRIVER_LAYER:UTIL
!
! module_gpu_callcheck: in-model check of one ported routine on real data
! (port/agent/DEBUGGING.md section 0b; the call-check code of the island,
! port/tools/gen_island.py).
!
!   WRF_GPU_CALLCHECK=<route>[:<n>|:all]   check the first n calls (default 1)
!   WRF_GPU_CALLCHECK_STOP=1               stop the run after the last check
!
! A checked call runs the routine twice with the same inputs:
!   pass 1  the route on the device (its island moves the arguments): at
!           entry every argument the routine may change (INTENT(OUT/INOUT)
!           arrays and scalars) is saved; at exit the device results are kept
!           and the inputs restored; the routine jumps back to its entry;
!   pass 2  every route on the host (a pure host execution, as CPU-REF);
!           at exit each argument is compared bit for bit with the device
!           result, and the call is reported:
!     gpu_callcheck: <route> call <n>: PASS (<a> arrays, <s> scalars bit-identical)
!     gpu_callcheck: <route> call <n>: DIFF <name>(i,k,j) host <value> (Z<bits>) device <value> (Z<bits>), <m> of <n> values differ
!     gpu_callcheck: <route> call <n>: FAIL (<d> of <a> arguments differ)
! The model continues with the host results.  Only in the host world
! (Phases 1-4: gpu_world_host); only for routes switched on.  Arrays the
! routine changes that are not arguments (module arrays) are not saved: add
! them to the island and to the check by hand (CODING_STANDARD.md section 3).
! Without WRF_GPU every function returns .FALSE. and nothing happens.
!
MODULE module_gpu_callcheck

   USE module_gpu_route, ONLY : gpu_on, gpu_world_host, nroutes, route_name, gpu_route_index

   IMPLICIT NONE
   PRIVATE

   PUBLIC :: gpu_cc_start, gpu_cc_active, gpu_cc_next
   PUBLIC :: gpu_cc_save_r, gpu_cc_save_d, gpu_cc_save_i, gpu_cc_save_l
   PUBLIC :: gpu_cc_save_r0, gpu_cc_save_d0, gpu_cc_save_i0, gpu_cc_save_l0
   PUBLIC :: gpu_cc_done_r, gpu_cc_done_d, gpu_cc_done_i, gpu_cc_done_l
   PUBLIC :: gpu_cc_done_r0, gpu_cc_done_d0, gpu_cc_done_i0, gpu_cc_done_l0

   INTEGER, PARAMETER :: MAXSLOT = 400

   TYPE ccbuf
      REAL, ALLOCATABLE :: r(:), rd(:)
      DOUBLE PRECISION, ALLOCATABLE :: d(:), dd(:)
      INTEGER, ALLOCATABLE :: i(:), id(:)
      LOGICAL, ALLOCATABLE :: l(:), ld(:)
   END TYPE ccbuf

   TYPE(ccbuf), SAVE :: buf(MAXSLOT)
   LOGICAL, SAVE :: ready = .FALSE., stop_after = .FALSE.
   LOGICAL, SAVE :: saved_on(nroutes)
   INTEGER, SAVE :: sel = 0            ! the route to check (0: none)
   INTEGER, SAVE :: maxcalls = 1       ! 0: every call
   INTEGER, SAVE :: ncalls = 0         ! calls checked so far
   INTEGER, SAVE :: pass = 0           ! 0 idle, 1 device pass, 2 host pass
   INTEGER, SAVE :: narr = 0, nsca = 0, ndiff = 0

CONTAINS

   SUBROUTINE cc_init()
      USE module_wrf_error
      CHARACTER(LEN=256) :: v
      INTEGER :: st, c
      ready = .TRUE.
      CALL get_environment_variable('WRF_GPU_CALLCHECK', v, status=st)
      IF (st /= 0 .OR. LEN_TRIM(v) == 0) RETURN
      c = INDEX(v, ':')
      IF (c > 0) THEN
         IF (TRIM(v(c + 1:)) == 'all') THEN
            maxcalls = 0
         ELSE
            READ (v(c + 1:), *, iostat=st) maxcalls
            IF (st /= 0 .OR. maxcalls < 1) CALL wrf_error_fatal('gpu_callcheck: WRF_GPU_CALLCHECK=<route>[:<n>|:all]')
         END IF
         v = v(1:c - 1)
      END IF
      sel = gpu_route_index(TRIM(ADJUSTL(v)))
      IF (sel == 0) CALL wrf_error_fatal('gpu_callcheck: unknown route "'//TRIM(v)//'" in WRF_GPU_CALLCHECK')
      CALL get_environment_variable('WRF_GPU_CALLCHECK_STOP', v, status=st)
      stop_after = st == 0 .AND. TRIM(v) == '1'
      WRITE (wrf_err_message, '(a,a,a,i0,a)') 'gpu_callcheck: checking route ', TRIM(route_name(sel)), &
         ' (', maxcalls, ' calls; 0 = all)'
      CALL wrf_message(TRIM(wrf_err_message))
   END SUBROUTINE cc_init

   ! At the entry of route r: .TRUE. if this call is checked (pass 1 starts).
   LOGICAL FUNCTION gpu_cc_start(r)
      INTEGER, INTENT(IN) :: r
      gpu_cc_start = .FALSE.
#ifdef WRF_GPU
      IF (.NOT. ready) CALL cc_init()
      IF (sel /= r .OR. pass /= 0) RETURN          ! not this route, or the host pass of a check
      IF (.NOT. gpu_world_host .OR. .NOT. gpu_on(r)) RETURN
      IF (maxcalls > 0 .AND. ncalls >= maxcalls) RETURN
      ncalls = ncalls + 1
      pass = 1
      narr = 0
      nsca = 0
      ndiff = 0
      gpu_cc_start = .TRUE.
#endif
   END FUNCTION gpu_cc_start

   ! At the exit of route r: .TRUE. while a check of r is running.
   LOGICAL FUNCTION gpu_cc_active(r)
      INTEGER, INTENT(IN) :: r
      gpu_cc_active = .FALSE.
#ifdef WRF_GPU
      gpu_cc_active = pass > 0 .AND. sel == r
#endif
   END FUNCTION gpu_cc_active

   ! At the exit of route r, after the gpu_cc_done_* calls: .TRUE. = run the
   ! routine again (jump to its entry label) for the host pass.
   LOGICAL FUNCTION gpu_cc_next(r)
      USE module_wrf_error
      INTEGER, INTENT(IN) :: r
      gpu_cc_next = .FALSE.
#ifdef WRF_GPU
      IF (pass == 1) THEN
         saved_on = gpu_on
         gpu_on = .FALSE.
         pass = 2
         gpu_cc_next = .TRUE.
         RETURN
      END IF
      gpu_on = saved_on
      pass = 0
      IF (ndiff == 0) THEN
         WRITE (wrf_err_message, '(a,a,a,i0,a,i0,a,i0,a)') 'gpu_callcheck: ', TRIM(route_name(r)), ' call ', ncalls, &
            ': PASS (', narr, ' arrays, ', nsca, ' scalars bit-identical)'
      ELSE
         WRITE (wrf_err_message, '(a,a,a,i0,a,i0,a,i0,a)') 'gpu_callcheck: ', TRIM(route_name(r)), ' call ', ncalls, &
            ': FAIL (', ndiff, ' of ', narr + nsca, ' arguments differ)'
      END IF
      CALL wrf_message(TRIM(wrf_err_message))
      IF (stop_after .AND. maxcalls > 0 .AND. ncalls >= maxcalls) &
         CALL wrf_error_fatal('gpu_callcheck: done (WRF_GPU_CALLCHECK_STOP=1)')
#endif
   END FUNCTION gpu_cc_next

   ! ---- saving at entry (pass 1 only)
   SUBROUTINE gpu_cc_save_r(slot, a, n)
      INTEGER, INTENT(IN) :: slot
      INTEGER(KIND=8), INTENT(IN) :: n
      REAL, INTENT(IN) :: a(*)
      IF (pass /= 1) RETURN
      IF (ALLOCATED(buf(slot)%r)) DEALLOCATE (buf(slot)%r)
      ALLOCATE (buf(slot)%r(n))
      buf(slot)%r = a(1:n)
   END SUBROUTINE gpu_cc_save_r
   SUBROUTINE gpu_cc_save_d(slot, a, n)
      INTEGER, INTENT(IN) :: slot
      INTEGER(KIND=8), INTENT(IN) :: n
      DOUBLE PRECISION, INTENT(IN) :: a(*)
      IF (pass /= 1) RETURN
      IF (ALLOCATED(buf(slot)%d)) DEALLOCATE (buf(slot)%d)
      ALLOCATE (buf(slot)%d(n))
      buf(slot)%d = a(1:n)
   END SUBROUTINE gpu_cc_save_d
   SUBROUTINE gpu_cc_save_i(slot, a, n)
      INTEGER, INTENT(IN) :: slot
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: a(*)
      IF (pass /= 1) RETURN
      IF (ALLOCATED(buf(slot)%i)) DEALLOCATE (buf(slot)%i)
      ALLOCATE (buf(slot)%i(n))
      buf(slot)%i = a(1:n)
   END SUBROUTINE gpu_cc_save_i
   SUBROUTINE gpu_cc_save_l(slot, a, n)
      INTEGER, INTENT(IN) :: slot
      INTEGER(KIND=8), INTENT(IN) :: n
      LOGICAL, INTENT(IN) :: a(*)
      IF (pass /= 1) RETURN
      IF (ALLOCATED(buf(slot)%l)) DEALLOCATE (buf(slot)%l)
      ALLOCATE (buf(slot)%l(n))
      buf(slot)%l = a(1:n)
   END SUBROUTINE gpu_cc_save_l
   SUBROUTINE gpu_cc_save_r0(slot, x)
      INTEGER, INTENT(IN) :: slot
      REAL, INTENT(IN) :: x
      REAL :: a(1)
      a(1) = x
      CALL gpu_cc_save_r(slot, a, 1_8)
   END SUBROUTINE gpu_cc_save_r0
   SUBROUTINE gpu_cc_save_d0(slot, x)
      INTEGER, INTENT(IN) :: slot
      DOUBLE PRECISION, INTENT(IN) :: x
      DOUBLE PRECISION :: a(1)
      a(1) = x
      CALL gpu_cc_save_d(slot, a, 1_8)
   END SUBROUTINE gpu_cc_save_d0
   SUBROUTINE gpu_cc_save_i0(slot, x)
      INTEGER, INTENT(IN) :: slot
      INTEGER, INTENT(IN) :: x
      INTEGER :: a(1)
      a(1) = x
      CALL gpu_cc_save_i(slot, a, 1_8)
   END SUBROUTINE gpu_cc_save_i0
   SUBROUTINE gpu_cc_save_l0(slot, x)
      INTEGER, INTENT(IN) :: slot
      LOGICAL, INTENT(IN) :: x
      LOGICAL :: a(1)
      a(1) = x
      CALL gpu_cc_save_l(slot, a, 1_8)
   END SUBROUTINE gpu_cc_save_l0

   ! ---- at exit: pass 1 keeps the device result and restores the input,
   !      pass 2 compares the host result with the device result
   SUBROUTINE gpu_cc_done_r(slot, a, n, name, lb, ub)
      INTEGER, INTENT(IN) :: slot, lb(:), ub(:)
      INTEGER(KIND=8), INTENT(IN) :: n
      REAL, INTENT(INOUT) :: a(*)
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER(KIND=8) :: k, first, m
      IF (pass == 1) THEN
         IF (ALLOCATED(buf(slot)%rd)) DEALLOCATE (buf(slot)%rd)
         ALLOCATE (buf(slot)%rd(n))
         buf(slot)%rd = a(1:n)
         a(1:n) = buf(slot)%r
      ELSE IF (pass == 2) THEN
         m = 0
         first = 0
         DO k = 1, n
            IF (TRANSFER(a(k), 0) /= TRANSFER(buf(slot)%rd(k), 0)) THEN
               m = m + 1
               IF (first == 0) first = k
            END IF
         END DO
         CALL count_arg(SIZE(lb) > 0)
         IF (m > 0) CALL report(name, lb, ub, first, m, n, rv(a(first)), rv(buf(slot)%rd(first)), &
                                INT(TRANSFER(a(first), 0), 8), INT(TRANSFER(buf(slot)%rd(first), 0), 8), 8)
         DEALLOCATE (buf(slot)%r, buf(slot)%rd)
      END IF
   END SUBROUTINE gpu_cc_done_r
   SUBROUTINE gpu_cc_done_d(slot, a, n, name, lb, ub)
      INTEGER, INTENT(IN) :: slot, lb(:), ub(:)
      INTEGER(KIND=8), INTENT(IN) :: n
      DOUBLE PRECISION, INTENT(INOUT) :: a(*)
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER(KIND=8) :: k, first, m
      IF (pass == 1) THEN
         IF (ALLOCATED(buf(slot)%dd)) DEALLOCATE (buf(slot)%dd)
         ALLOCATE (buf(slot)%dd(n))
         buf(slot)%dd = a(1:n)
         a(1:n) = buf(slot)%d
      ELSE IF (pass == 2) THEN
         m = 0
         first = 0
         DO k = 1, n
            IF (TRANSFER(a(k), 0_8) /= TRANSFER(buf(slot)%dd(k), 0_8)) THEN
               m = m + 1
               IF (first == 0) first = k
            END IF
         END DO
         CALL count_arg(SIZE(lb) > 0)
         IF (m > 0) CALL report(name, lb, ub, first, m, n, a(first), buf(slot)%dd(first), &
                                TRANSFER(a(first), 0_8), TRANSFER(buf(slot)%dd(first), 0_8), 16)
         DEALLOCATE (buf(slot)%d, buf(slot)%dd)
      END IF
   END SUBROUTINE gpu_cc_done_d
   SUBROUTINE gpu_cc_done_i(slot, a, n, name, lb, ub)
      INTEGER, INTENT(IN) :: slot, lb(:), ub(:)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(INOUT) :: a(*)
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER(KIND=8) :: k, first, m
      IF (pass == 1) THEN
         IF (ALLOCATED(buf(slot)%id)) DEALLOCATE (buf(slot)%id)
         ALLOCATE (buf(slot)%id(n))
         buf(slot)%id = a(1:n)
         a(1:n) = buf(slot)%i
      ELSE IF (pass == 2) THEN
         m = 0
         first = 0
         DO k = 1, n
            IF (a(k) /= buf(slot)%id(k)) THEN
               m = m + 1
               IF (first == 0) first = k
            END IF
         END DO
         CALL count_arg(SIZE(lb) > 0)
         IF (m > 0) CALL report(name, lb, ub, first, m, n, DBLE(a(first)), DBLE(buf(slot)%id(first)), &
                                INT(a(first), 8), INT(buf(slot)%id(first), 8), 8)
         DEALLOCATE (buf(slot)%i, buf(slot)%id)
      END IF
   END SUBROUTINE gpu_cc_done_i
   SUBROUTINE gpu_cc_done_l(slot, a, n, name, lb, ub)
      INTEGER, INTENT(IN) :: slot, lb(:), ub(:)
      INTEGER(KIND=8), INTENT(IN) :: n
      LOGICAL, INTENT(INOUT) :: a(*)
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER(KIND=8) :: k, first, m
      IF (pass == 1) THEN
         IF (ALLOCATED(buf(slot)%ld)) DEALLOCATE (buf(slot)%ld)
         ALLOCATE (buf(slot)%ld(n))
         buf(slot)%ld = a(1:n)
         a(1:n) = buf(slot)%l
      ELSE IF (pass == 2) THEN
         m = 0
         first = 0
         DO k = 1, n
            IF (a(k) .NEQV. buf(slot)%ld(k)) THEN
               m = m + 1
               IF (first == 0) first = k
            END IF
         END DO
         CALL count_arg(SIZE(lb) > 0)
         IF (m > 0) CALL report(name, lb, ub, first, m, n, MERGE(1.D0, 0.D0, a(first)), &
                                MERGE(1.D0, 0.D0, buf(slot)%ld(first)), MERGE(1_8, 0_8, a(first)), &
                                MERGE(1_8, 0_8, buf(slot)%ld(first)), 1)
         DEALLOCATE (buf(slot)%l, buf(slot)%ld)
      END IF
   END SUBROUTINE gpu_cc_done_l
   SUBROUTINE gpu_cc_done_r0(slot, x, name)
      INTEGER, INTENT(IN) :: slot
      REAL, INTENT(INOUT) :: x
      CHARACTER(LEN=*), INTENT(IN) :: name
      REAL :: a(1)
      INTEGER :: none(0)
      a(1) = x
      CALL gpu_cc_done_r(slot, a, 1_8, name, none, none)
      x = a(1)
   END SUBROUTINE gpu_cc_done_r0
   SUBROUTINE gpu_cc_done_d0(slot, x, name)
      INTEGER, INTENT(IN) :: slot
      DOUBLE PRECISION, INTENT(INOUT) :: x
      CHARACTER(LEN=*), INTENT(IN) :: name
      DOUBLE PRECISION :: a(1)
      INTEGER :: none(0)
      a(1) = x
      CALL gpu_cc_done_d(slot, a, 1_8, name, none, none)
      x = a(1)
   END SUBROUTINE gpu_cc_done_d0
   SUBROUTINE gpu_cc_done_i0(slot, x, name)
      INTEGER, INTENT(IN) :: slot
      INTEGER, INTENT(INOUT) :: x
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER :: a(1)
      INTEGER :: none(0)
      a(1) = x
      CALL gpu_cc_done_i(slot, a, 1_8, name, none, none)
      x = a(1)
   END SUBROUTINE gpu_cc_done_i0
   SUBROUTINE gpu_cc_done_l0(slot, x, name)
      INTEGER, INTENT(IN) :: slot
      LOGICAL, INTENT(INOUT) :: x
      CHARACTER(LEN=*), INTENT(IN) :: name
      LOGICAL :: a(1)
      INTEGER :: none(0)
      a(1) = x
      CALL gpu_cc_done_l(slot, a, 1_8, name, none, none)
      x = a(1)
   END SUBROUTINE gpu_cc_done_l0

   ! ---- helpers
   DOUBLE PRECISION FUNCTION rv(x)
      REAL, INTENT(IN) :: x
      rv = DBLE(x)
   END FUNCTION rv

   SUBROUTINE count_arg(is_array)
      LOGICAL, INTENT(IN) :: is_array
      IF (is_array) THEN
         narr = narr + 1
      ELSE
         nsca = nsca + 1
      END IF
   END SUBROUTINE count_arg

   ! one DIFF line: the first differing element with its index in the bounds
   ! of the dummy argument, both values and their bits
   SUBROUTINE report(name, lb, ub, first, m, n, hv, dv, hb, db, nhex)
      USE module_wrf_error
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER, INTENT(IN) :: lb(:), ub(:), nhex
      INTEGER(KIND=8), INTENT(IN) :: first, m, n, hb, db
      DOUBLE PRECISION, INTENT(IN) :: hv, dv
      CHARACTER(LEN=128) :: idx
      CHARACTER(LEN=40) :: hs, ds, w
      INTEGER(KIND=8) :: p, ext
      INTEGER :: d
      ndiff = ndiff + 1
      idx = ''
      p = first - 1
      DO d = 1, SIZE(lb)
         ext = INT(ub(d) - lb(d) + 1, 8)
         WRITE (w, '(i0)') lb(d) + INT(MOD(p, ext))
         idx = TRIM(idx)//MERGE('(', ',', d == 1)//TRIM(w)
         p = p/ext
      END DO
      IF (SIZE(lb) > 0) idx = TRIM(idx)//')'
      IF (nhex == 16) THEN
         WRITE (hs, '(z16.16)') hb
         WRITE (ds, '(z16.16)') db
      ELSE
         WRITE (hs, '(z8.8)') INT(hb, 4)
         WRITE (ds, '(z8.8)') INT(db, 4)
      END IF
      WRITE (wrf_err_message, '(a,a,a,i0,a,a,a,es16.8e3,a,a,a,es16.8e3,a,a,a,i0,a,i0,a)') 'gpu_callcheck: ', &
         TRIM(route_name(sel)), ' call ', ncalls, ': DIFF ', TRIM(name)//TRIM(idx), ' host ', &
         hv, ' (Z', TRIM(hs), ') device ', dv, ' (Z', TRIM(ds), '), ', m, ' of ', n, ' values differ'
      CALL wrf_message(TRIM(wrf_err_message))
   END SUBROUTINE report

END MODULE module_gpu_callcheck
