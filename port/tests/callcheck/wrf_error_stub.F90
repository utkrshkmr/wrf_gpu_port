! Minimal module_wrf_error for the standalone tests (prints instead of the
! WRF message machinery).
MODULE module_wrf_error
   IMPLICIT NONE
   CHARACTER(LEN=256) :: wrf_err_message
CONTAINS
   SUBROUTINE wrf_message(s)
      CHARACTER(LEN=*), INTENT(IN) :: s
      PRINT '(a)', TRIM(s)
   END SUBROUTINE wrf_message
   SUBROUTINE wrf_error_fatal(s)
      CHARACTER(LEN=*), INTENT(IN) :: s
      PRINT '(a,a)', 'FATAL ', TRIM(s)
      STOP 3
   END SUBROUTINE wrf_error_fatal
END MODULE module_wrf_error
