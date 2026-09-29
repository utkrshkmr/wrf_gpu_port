! F-IFTARGET (plan.md P0.5b): with if(target: .false.) the region must run on
! the host and use the host copy of mapped data.
PROGRAM f_iftarget
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: n = 1000
   REAL :: a(n)
   LOGICAL :: flag, ondev
   INTEGER :: i
   a = 1.0
!$omp target enter data map(to: a)
   a = 2.0                              ! host copy differs from device copy
   flag = .FALSE.
   ondev = .TRUE.
!$omp target teams distribute parallel do if(target: flag) map(tofrom: ondev)
   DO i = 1, n
      a(i) = a(i) + 1.0
      IF (i == 1) ondev = .NOT. omp_is_initial_device()
   END DO
   ! host copy must now be 3; device copy still 1
   IF (ALL(a == 3.0) .AND. .NOT. ondev) THEN
!$omp target update from(a)
      IF (ALL(a == 1.0)) THEN
         PRINT '(a)', 'PROBE F-IFTARGET PASS'
         STOP
      END IF
   END IF
   PRINT '(a,l2,f6.1)', 'PROBE F-IFTARGET FAIL ran_on_device,a(1)=', ondev, a(1)
END PROGRAM f_iftarget
