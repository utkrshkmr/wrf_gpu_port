! F-RED, F-NAN (plan.md P0.5b): reduction(+:) and reduction(ieor:) on
! INTEGER(8) (bit-hash tracer), reduction(max:) on REAL, and the x /= x NaN
! test on the device.
PROGRAM f_red
   IMPLICIT NONE
   INTEGER, PARAMETER :: i8 = SELECTED_INT_KIND(18)
   INTEGER, PARAMETER :: n = 1000000
   REAL, ALLOCATABLE :: a(:)
   INTEGER(i8) :: hs, hx, hs_h, hx_h
   INTEGER :: i, nnan, nnan_h
   REAL :: mx, mx_h, zero
   ALLOCATE (a(n))
   DO i = 1, n
      a(i) = SIN(REAL(i))*1000.0
   END DO
   zero = 0.0
   a(17) = zero/zero
   a(99) = zero/zero
   hs = 0; hx = 0; mx = -HUGE(1.0); nnan = 0
!$omp target teams distribute parallel do map(to: a) reduction(+: hs, nnan) reduction(ieor: hx) reduction(max: mx)
   DO i = 1, n
      hs = hs + INT(TRANSFER(a(i), 0), i8)
      hx = IEOR(hx, INT(TRANSFER(a(i), 0), i8)*INT(i, i8))
      IF (a(i) /= a(i)) THEN
         nnan = nnan + 1
      ELSE
         mx = MAX(mx, a(i))
      END IF
   END DO
   hs_h = 0; hx_h = 0; mx_h = -HUGE(1.0); nnan_h = 0
   DO i = 1, n
      hs_h = hs_h + INT(TRANSFER(a(i), 0), i8)
      hx_h = IEOR(hx_h, INT(TRANSFER(a(i), 0), i8)*INT(i, i8))
      IF (a(i) /= a(i)) THEN
         nnan_h = nnan_h + 1
      ELSE
         mx_h = MAX(mx_h, a(i))
      END IF
   END DO
   IF (hs == hs_h .AND. hx == hx_h .AND. mx == mx_h) THEN
      PRINT '(a)', 'PROBE F-RED PASS'
   ELSE
      PRINT '(a,3l2)', 'PROBE F-RED FAIL sum,xor,max=', hs == hs_h, hx == hx_h, mx == mx_h
   END IF
   IF (nnan == 2 .AND. nnan_h == 2) THEN
      PRINT '(a)', 'PROBE F-NAN PASS'
   ELSE
      PRINT '(a,2i4)', 'PROBE F-NAN FAIL device,host NaN counts=', nnan, nnan_h
   END IF
END PROGRAM f_red
