! F-COMPMAP-ADDR (plan.md P1.2, P1.3; port/agent/PHASE1.md H0.3): device
! mapping of the fields of a WRF-like TYPE(domain) BY ADDRESS, the form the
! generated code uses (WRF/frame/module_gpu_map.F).
!
! The fields are ALLOCATABLE components (WRF builds with -DUSE_ALLOCATABLES,
! arch/postamble) of a POINTER grid, allocated with WRF bounds
! (ims:ime,kms:kme,jms:jme), like inc/allocs.inc does.  Each one is
! passed to a routine whose assumed-size dummy is mapped with
! enter data map(to: a(1:n)), moved with target update and released with
! exit data map(delete: a(1:n)).  Checked:
!   1. every field is present (omp_target_is_present of its first element);
!   2. a kernel that receives a field as an explicit-shape dummy (as every
!      WRF kernel and island does) uses the device copy without any copy: the
!      host copy is unchanged until the update from;
!   3. updates in both directions move the data;
!   4. a slice of a 4D field (moist(:,:,:,2)) passed to an explicit-shape
!      dummy is found present (part of the mapped 4D array);
!   5. INTEGER and LOGICAL fields, (1,1,1) dummies and two grids at once;
!   6. an intermediate grid that is never mapped is not present;
!   7. after exit data the fields are no longer present.
! f_compmap_member.F90 tries the structure-member form map(to:grid%f) for
! information (not used by the port).
MODULE compmap_m
   USE omp_lib
   USE iso_c_binding
   IMPLICIT NONE
   INTEGER, PARAMETER :: GPU_MAP_ENTER = 1, GPU_MAP_EXIT = 2, GPU_UPD_TO = 3, GPU_UPD_FROM = 4
   TYPE dom
      INTEGER :: id
      LOGICAL :: is_intermediate
      REAL, ALLOCATABLE :: u_2(:,:,:), v_2(:,:,:), w_2(:,:,:), t_2(:,:,:), ph_2(:,:,:)
      REAL, ALLOCATABLE :: p(:,:,:), al(:,:,:), alt(:,:,:), z(:,:,:), tke_2(:,:,:)
      REAL, ALLOCATABLE :: mu_2(:,:), mub(:,:), ht(:,:), msftx(:,:), xlat(:,:)
      REAL, ALLOCATABLE :: u_bxs(:,:,:), u_bxe(:,:,:), u_bys(:,:,:), u_bye(:,:,:)
      REAL, ALLOCATABLE :: moist(:,:,:,:)
      REAL, ALLOCATABLE :: unused3(:,:,:)
      INTEGER, ALLOCATABLE :: ivgtyp(:,:), isltyp(:,:)
      LOGICAL, ALLOCATABLE :: lmask(:,:)
   END TYPE dom
CONTAINS

   SUBROUTINE gpu_map_r(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      REAL :: a(*)
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
   END SUBROUTINE gpu_map_r

   SUBROUTINE gpu_map_i(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      INTEGER :: a(*)
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
   END SUBROUTINE gpu_map_i

   SUBROUTINE gpu_map_l(a, n, op)
      INTEGER(KIND=8), INTENT(IN) :: n
      INTEGER, INTENT(IN) :: op
      LOGICAL :: a(*)
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
   END SUBROUTINE gpu_map_l

   ! allocation as inc/allocs.inc does it: ALLOCATE, initial value, then (GPU) map
   SUBROUTINE alloc_dom(grid, id, inter, ims, ime, kms, kme, jms, jme, nmoist, mapit)
      TYPE(dom), POINTER :: grid
      INTEGER, INTENT(IN) :: id, ims, ime, kms, kme, jms, jme, nmoist
      LOGICAL, INTENT(IN) :: inter, mapit
      ALLOCATE (grid)
      grid%id = id
      grid%is_intermediate = inter
#define A3(f) ALLOCATE(grid%f(ims:ime,kms:kme,jms:jme)); grid%f = 0.
#define A2(f) ALLOCATE(grid%f(ims:ime,jms:jme)); grid%f = 0.
      A3(u_2)
      A3(v_2)
      A3(w_2)
      A3(t_2)
      A3(ph_2)
      A3(p)
      A3(al)
      A3(alt)
      A3(z)
      A3(tke_2)
      A2(mu_2)
      A2(mub)
      A2(ht)
      A2(msftx)
      A2(xlat)
      ALLOCATE (grid%u_bxs(jms:jme,kms:kme,5)); grid%u_bxs = 0.
      ALLOCATE (grid%u_bxe(jms:jme,kms:kme,5)); grid%u_bxe = 0.
      ALLOCATE (grid%u_bys(ims:ime,kms:kme,5)); grid%u_bys = 0.
      ALLOCATE (grid%u_bye(ims:ime,kms:kme,5)); grid%u_bye = 0.
      ALLOCATE (grid%moist(ims:ime,kms:kme,jms:jme,nmoist)); grid%moist = 0.
      ALLOCATE (grid%unused3(1,1,1)); grid%unused3 = 0.
      ALLOCATE (grid%ivgtyp(ims:ime,jms:jme)); grid%ivgtyp = 0
      ALLOCATE (grid%isltyp(ims:ime,jms:jme)); grid%isltyp = 0
      ALLOCATE (grid%lmask(ims:ime,jms:jme)); grid%lmask = .FALSE.
      IF (mapit .AND. .NOT. grid%is_intermediate) CALL map_all(grid, GPU_MAP_ENTER)
   END SUBROUTINE alloc_dom

   SUBROUTINE map_all(grid, op)
      TYPE(dom), POINTER :: grid
      INTEGER, INTENT(IN) :: op
#define MR(f) CALL gpu_map_r(grid%f, SIZE(grid%f,KIND=8), op)
      MR(u_2)
      MR(v_2)
      MR(w_2)
      MR(t_2)
      MR(ph_2)
      MR(p)
      MR(al)
      MR(alt)
      MR(z)
      MR(tke_2)
      MR(mu_2)
      MR(mub)
      MR(ht)
      MR(msftx)
      MR(xlat)
      MR(u_bxs)
      MR(u_bxe)
      MR(u_bys)
      MR(u_bye)
      MR(moist)
      MR(unused3)
      CALL gpu_map_i(grid%ivgtyp, SIZE(grid%ivgtyp,KIND=8), op)
      CALL gpu_map_i(grid%isltyp, SIZE(grid%isltyp,KIND=8), op)
      CALL gpu_map_l(grid%lmask, SIZE(grid%lmask,KIND=8), op)
   END SUBROUTINE map_all

   ! number of fields whose first element is present on the device
   INTEGER FUNCTION n_present(grid)
      TYPE(dom), POINTER :: grid
      n_present = 0
      IF (pr3(grid%u_2)) n_present = n_present + 1
      IF (pr3(grid%v_2)) n_present = n_present + 1
      IF (pr3(grid%w_2)) n_present = n_present + 1
      IF (pr3(grid%t_2)) n_present = n_present + 1
      IF (pr3(grid%ph_2)) n_present = n_present + 1
      IF (pr3(grid%p)) n_present = n_present + 1
      IF (pr3(grid%al)) n_present = n_present + 1
      IF (pr3(grid%alt)) n_present = n_present + 1
      IF (pr3(grid%z)) n_present = n_present + 1
      IF (pr3(grid%tke_2)) n_present = n_present + 1
      IF (pr3(grid%u_bxs)) n_present = n_present + 1
      IF (pr3(grid%u_bxe)) n_present = n_present + 1
      IF (pr3(grid%u_bys)) n_present = n_present + 1
      IF (pr3(grid%u_bye)) n_present = n_present + 1
      IF (pr3(grid%unused3)) n_present = n_present + 1
      IF (pr2(grid%mu_2)) n_present = n_present + 1
      IF (pr2(grid%mub)) n_present = n_present + 1
      IF (pr2(grid%ht)) n_present = n_present + 1
      IF (pr2(grid%msftx)) n_present = n_present + 1
      IF (pr2(grid%xlat)) n_present = n_present + 1
      IF (pr4(grid%moist)) n_present = n_present + 1
      IF (pi2(grid%ivgtyp)) n_present = n_present + 1
      IF (pi2(grid%isltyp)) n_present = n_present + 1
      IF (pl2(grid%lmask)) n_present = n_present + 1
   END FUNCTION n_present

   LOGICAL FUNCTION pr3(a)
      REAL, INTENT(IN), TARGET :: a(:,:,:)
      pr3 = omp_target_is_present(C_LOC(a(1, 1, 1)), omp_get_default_device()) /= 0
   END FUNCTION pr3
   LOGICAL FUNCTION pr2(a)
      REAL, INTENT(IN), TARGET :: a(:,:)
      pr2 = omp_target_is_present(C_LOC(a(1, 1)), omp_get_default_device()) /= 0
   END FUNCTION pr2
   LOGICAL FUNCTION pr4(a)
      REAL, INTENT(IN), TARGET :: a(:,:,:,:)
      pr4 = omp_target_is_present(C_LOC(a(1, 1, 1, 1)), omp_get_default_device()) /= 0
   END FUNCTION pr4
   LOGICAL FUNCTION pi2(a)
      INTEGER, INTENT(IN), TARGET :: a(:,:)
      pi2 = omp_target_is_present(C_LOC(a(1, 1)), omp_get_default_device()) /= 0
   END FUNCTION pi2
   LOGICAL FUNCTION pl2(a)
      LOGICAL, INTENT(IN), TARGET :: a(:,:)
      pl2 = omp_target_is_present(C_LOC(a(1, 1)), omp_get_default_device()) /= 0
   END FUNCTION pl2

   ! WRF-style kernels: explicit-shape dummies, no map clause
   SUBROUTINE kern_add(a, ims, ime, kms, kme, jms, jme, c)
      INTEGER, INTENT(IN) :: ims, ime, kms, kme, jms, jme
      REAL, INTENT(INOUT) :: a(ims:ime, kms:kme, jms:jme)
      REAL, INTENT(IN) :: c
      INTEGER :: i, k, j
!$omp target teams distribute parallel do collapse(3)
      DO j = jms, jme
         DO k = kms, kme
            DO i = ims, ime
               a(i, k, j) = a(i, k, j) + c + REAL(i - ims) + 10.*REAL(k - kms)
            END DO
         END DO
      END DO
   END SUBROUTINE kern_add

   SUBROUTINE kern_copy(dst, src, ims, ime, kms, kme, jms, jme)
      INTEGER, INTENT(IN) :: ims, ime, kms, kme, jms, jme
      REAL, INTENT(OUT) :: dst(ims:ime, kms:kme, jms:jme)
      REAL, INTENT(IN) :: src(ims:ime, kms:kme, jms:jme)
      INTEGER :: i, k, j
!$omp target teams distribute parallel do collapse(3)
      DO j = jms, jme
         DO k = kms, kme
            DO i = ims, ime
               dst(i, k, j) = 2.*src(i, k, j)
            END DO
         END DO
      END DO
   END SUBROUTINE kern_copy

   SUBROUTINE kern_int(iv, ims, ime, jms, jme)
      INTEGER, INTENT(IN) :: ims, ime, jms, jme
      INTEGER, INTENT(INOUT) :: iv(ims:ime, jms:jme)
      INTEGER :: i, j
!$omp target teams distribute parallel do collapse(2)
      DO j = jms, jme
         DO i = ims, ime
            iv(i, j) = iv(i, j) + i + 100*j
         END DO
      END DO
   END SUBROUTINE kern_int
END MODULE compmap_m

PROGRAM f_compmap
   USE compmap_m
   IMPLICIT NONE
   INTEGER, PARAMETER :: ims = -4, ime = 45, kms = 1, kme = 31, jms = -4, jme = 37, nmoist = 7
   INTEGER, PARAMETER :: nfields = 24
   TYPE(dom), POINTER :: g1, g2, gi
   INTEGER :: np1, np2, npi, npx, i, k, j
   LOGICAL :: nocopy, upd_from, upd_to, slice4, intok, ok
   CHARACTER(LEN=200) :: why

   IF (omp_get_num_devices() < 1) THEN
      PRINT '(a)', 'PROBE F-COMPMAP-ADDR SKIP (no device)'
      STOP
   END IF
   CALL alloc_dom(g1, 1, .FALSE., ims, ime, kms, kme, jms, jme, nmoist, .TRUE.)
   CALL alloc_dom(g2, 2, .FALSE., ims, ime, kms, kme, jms, jme, nmoist, .TRUE.)
   CALL alloc_dom(gi, 3, .TRUE., ims, ime, kms, kme, jms, jme, nmoist, .TRUE.)
   np1 = n_present(g1); np2 = n_present(g2); npi = n_present(gi)

   ! 2: kernel on the device copy, host unchanged until the update from
   CALL kern_add(g1%t_2, ims, ime, kms, kme, jms, jme, 300.)
   nocopy = ALL(g1%t_2 == 0.)
   CALL gpu_map_r(g1%t_2, SIZE(g1%t_2,KIND=8), GPU_UPD_FROM)
   upd_from = .TRUE.
   DO j = jms, jme
      DO k = kms, kme
         DO i = ims, ime
            IF (g1%t_2(i, k, j) /= 300. + REAL(i - ims) + 10.*REAL(k - kms)) upd_from = .FALSE.
         END DO
      END DO
   END DO
   ! 3: host change, update to, device reads it
   g1%p = 7.
   CALL gpu_map_r(g1%p, SIZE(g1%p,KIND=8), GPU_UPD_TO)
   CALL kern_copy(g1%al, g1%p, ims, ime, kms, kme, jms, jme)
   upd_to = ALL(g1%al == 0.)
   CALL gpu_map_r(g1%al, SIZE(g1%al,KIND=8), GPU_UPD_FROM)
   upd_to = upd_to .AND. ALL(g1%al == 14.)
   ! 4: a slice of the 4D field
   CALL kern_add(g1%moist(:,:,:,2), ims, ime, kms, kme, jms, jme, 1.)
   slice4 = ALL(g1%moist == 0.)
   CALL gpu_map_r(g1%moist, SIZE(g1%moist,KIND=8), GPU_UPD_FROM)
   slice4 = slice4 .AND. ALL(g1%moist(:,:,:,1) == 0.) .AND. ALL(g1%moist(:,:,:,3:) == 0.) .AND. &
            g1%moist(ims, kms, jms, 2) == 1. .AND. g1%moist(ime, kme, jme, 2) == 1. + REAL(ime - ims) + 10.*REAL(kme - kms)
   ! 5: integer field; the second grid is untouched
   CALL kern_int(g2%ivgtyp, ims, ime, jms, jme)
   intok = ALL(g2%ivgtyp == 0)
   CALL gpu_map_i(g2%ivgtyp, SIZE(g2%ivgtyp,KIND=8), GPU_UPD_FROM)
   intok = intok .AND. g2%ivgtyp(ims, jms) == ims + 100*jms .AND. g2%ivgtyp(ime, jme) == ime + 100*jme
   CALL gpu_map_r(g2%t_2, SIZE(g2%t_2,KIND=8), GPU_UPD_FROM)
   intok = intok .AND. ALL(g2%t_2 == 0.)
   ! 7: release
   CALL map_all(g1, GPU_MAP_EXIT)
   npx = n_present(g1)

   ok = np1 == nfields .AND. np2 == nfields .AND. npi == 0 .AND. nocopy .AND. upd_from .AND. upd_to &
        .AND. slice4 .AND. intok .AND. npx == 0
   WRITE (why, '(a,i0,a,i0,a,i0,a,i0,a,i0,a,6l2)') 'present ', np1, '/', nfields, ' second grid ', np2, &
      ' intermediate ', npi, ' after exit ', npx, '; nocopy,upd_from,upd_to,slice4D,int+2grids =', &
      nocopy, upd_from, upd_to, slice4, intok
   IF (ok) THEN
      PRINT '(a)', 'PROBE F-COMPMAP-ADDR PASS (' // TRIM(why) // ')'
   ELSE
      PRINT '(a)', 'PROBE F-COMPMAP-ADDR FAIL (' // TRIM(why) // ')'
   END IF
END PROGRAM f_compmap
