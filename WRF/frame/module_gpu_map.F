!WRF:DRIVER_LAYER:UTIL
!
! GPU port (plan.md P1.2, P1.3; port/agent/PHASE1.md): device mapping of the
! model state BY ADDRESS.
!
! The fields of TYPE(domain) are ALLOCATABLE components (-DUSE_ALLOCATABLES,
! arch/postamble).  The generated code
! (inc/allocs.inc, inc/deallocs.inc, inc/gpu_upd_*.inc) does not name them in
! OpenMP clauses (map(to:grid%u_2) is a structure-member map, whose behaviour
! differs between compilers).  It passes each field to one of the routines
! below, whose assumed-size dummy is the storage of the field; the clauses act on
! that storage.  Every kernel and island receives fields as explicit-shape
! dummies, so the device copy is found by address: the same rule everywhere.
! Probe F-COMPMAP (port/tests/omp_features/f_compmap.F90) checks this form,
! and the structure-member form for information, on the machine.
!
!   CALL gpu_map_r(grid%u_2, SIZE(grid%u_2,KIND=8), GPU_MAP_ENTER)
!
!   gpu_map_r / _d / _i / _l : REAL / DOUBLE PRECISION / INTEGER / LOGICAL fields
!   GPU_MAP_ENTER  target enter data map(to:)      (after ALLOCATE and the initial value)
!   GPU_MAP_EXIT   target exit data map(delete:)   (before DEALLOCATE)
!   GPU_UPD_TO     target update to                (host -> device)
!   GPU_UPD_FROM   target update from              (device -> host)
!
! The actual argument must be contiguous (an allocatable field always is); a
! non-contiguous one would be copied by the compiler and the temporary mapped
! instead, which T-MAP (gpu_selftest_map) reports as "not present".
! Without WRF_GPU the routines do nothing; they are only called under WRF_GPU.
!
MODULE module_gpu_map
   IMPLICIT NONE
   PRIVATE
   PUBLIC :: gpu_map_r, gpu_map_d, gpu_map_i, gpu_map_l
   PUBLIC :: GPU_MAP_ENTER, GPU_MAP_EXIT, GPU_UPD_TO, GPU_UPD_FROM
   INTEGER, PARAMETER :: GPU_MAP_ENTER = 1, GPU_MAP_EXIT = 2, GPU_UPD_TO = 3, GPU_UPD_FROM = 4
CONTAINS

   SUBROUTINE gpu_map_r(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      REAL :: a(*)
#ifdef WRF_GPU
      SELECT CASE (op)
      CASE (GPU_MAP_ENTER)
!$omp target enter data map(to: a(1:n))
      CASE (GPU_MAP_EXIT)
!$omp target exit data map(delete: a(1:n))
      CASE (GPU_UPD_TO)
!$omp target update to(a(1:n))
      CASE (GPU_UPD_FROM)
!$omp target update from(a(1:n))
      END SELECT
#endif
   END SUBROUTINE gpu_map_r

   SUBROUTINE gpu_map_d(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      DOUBLE PRECISION :: a(*)
#ifdef WRF_GPU
      SELECT CASE (op)
      CASE (GPU_MAP_ENTER)
!$omp target enter data map(to: a(1:n))
      CASE (GPU_MAP_EXIT)
!$omp target exit data map(delete: a(1:n))
      CASE (GPU_UPD_TO)
!$omp target update to(a(1:n))
      CASE (GPU_UPD_FROM)
!$omp target update from(a(1:n))
      END SELECT
#endif
   END SUBROUTINE gpu_map_d

   SUBROUTINE gpu_map_i(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      INTEGER :: a(*)
#ifdef WRF_GPU
      SELECT CASE (op)
      CASE (GPU_MAP_ENTER)
!$omp target enter data map(to: a(1:n))
      CASE (GPU_MAP_EXIT)
!$omp target exit data map(delete: a(1:n))
      CASE (GPU_UPD_TO)
!$omp target update to(a(1:n))
      CASE (GPU_UPD_FROM)
!$omp target update from(a(1:n))
      END SELECT
#endif
   END SUBROUTINE gpu_map_i

   SUBROUTINE gpu_map_l(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      LOGICAL :: a(*)
#ifdef WRF_GPU
      SELECT CASE (op)
      CASE (GPU_MAP_ENTER)
!$omp target enter data map(to: a(1:n))
      CASE (GPU_MAP_EXIT)
!$omp target exit data map(delete: a(1:n))
      CASE (GPU_UPD_TO)
!$omp target update to(a(1:n))
      CASE (GPU_UPD_FROM)
!$omp target update from(a(1:n))
      END SELECT
#endif
   END SUBROUTINE gpu_map_l

END MODULE module_gpu_map
