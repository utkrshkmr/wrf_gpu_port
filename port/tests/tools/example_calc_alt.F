SUBROUTINE calc_alt ( alt, al, alb,                  &
                      ids, ide, jds, jde, kds, kde,  &
                      ims, ime, jms, jme, kms, kme,  &
                      its, ite, jts, jte, kts, kte  )

   USE module_gpu_route, ONLY : gpu_on, gpu_island, gpu_world_host, R_CALC_ALT
   USE module_gpu_callcheck
   IMPLICIT NONE
   
   ! Input data

   INTEGER ,          INTENT(IN   ) :: ids, ide, jds, jde, kds, kde, &
                                       ims, ime, jms, jme, kms, kme, &
                                       its, ite, jts, jte, kts, kte

   REAL, DIMENSION( ims:ime , kms:kme , jms:jme ), INTENT(IN   ) :: alb, al
   REAL, DIMENSION( ims:ime , kms:kme , jms:jme ), INTENT(  OUT) :: alt

   ! Local stuff

   INTEGER :: i, j, k, itf, jtf, ktf
#ifdef WRF_GPU
   LOGICAL :: gpu_isl
#endif

!<DESCRIPTION>
!
! calc_alt computes the full inverse density
!
!</DESCRIPTION>

#ifdef WRF_GPU
99901 CONTINUE
      IF (gpu_cc_start(R_CALC_ALT)) THEN
        CALL gpu_cc_save_r(1, alt, SIZE(alt,KIND=8))
      END IF
      gpu_isl = gpu_island(R_CALC_ALT)
      IF (gpu_isl) THEN
        IF (gpu_world_host) THEN
!$omp target update to(alt, al, alb)
        ELSE
!$omp target update from(alt, al, alb)
        END IF
        gpu_world_host = .NOT. gpu_world_host
      END IF
#endif
      itf=MIN(ite,ide-1)
      jtf=MIN(jte,jde-1)
      ktf=MIN(kte,kde-1)

! K-PREP-7 (plan.md 7.1): Template A, directive in front of the unchanged loop
!$omp target teams distribute parallel do collapse(3) if(target: gpu_on(R_CALC_ALT)) default(none) &
!$omp& shared(alt, al, alb) firstprivate(its, itf, jts, jtf, kts, ktf)
      DO j=jts,jtf
      DO k=kts,ktf
      DO i=its,itf
        alt(i,k,j) = al(i,k,j)+alb(i,k,j)
      ENDDO
      ENDDO
      ENDDO

#ifdef WRF_GPU
      IF (gpu_isl) THEN
        gpu_world_host = .NOT. gpu_world_host
        IF (gpu_world_host) THEN
!$omp target update from(alt)
        ELSE
!$omp target update to(alt)
        END IF
      END IF
      IF (gpu_cc_active(R_CALC_ALT)) THEN
        CALL gpu_cc_done_r(1, alt, SIZE(alt,KIND=8), 'alt', &
          LBOUND(alt), UBOUND(alt))
        IF (gpu_cc_next(R_CALC_ALT)) GOTO 99901
      END IF
#endif

END SUBROUTINE calc_alt
