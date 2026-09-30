! Template G (plan.md 7.0/7.1, kernels K-BC-3D-x / K-BC-3D-y): boundary
! strips.  In set_physical_bc3d (WRF/share/module_bc.F, verbatim below) every
! loop nest of the open_xs / open_xe / open_ys / open_ye blocks is fully
! parallel (each (j,k) or (k,i) writes its own halo points from interior
! points that no strip of the same block writes).  So the port is only a
! directive in front of each nest, in place, with the host logic that picks
! the branch unchanged.  The order matters and is kept: the x strips run
! first over j = jts-bdyzone .. jte+bdyzone (they also fill the corner rows
! from whatever the y halo holds), then the y strips copy whole rows
! i = ims..ime including the x halo, which overwrites the corners.  Never
! merge the x and y strip kernels into one kernel (a race on the corners).
!
! The periodic and symmetric branches stay host loops: gpu_check_config
! rejects those options.  (In WRF the directives use
! if(target: gpu_on(R_SET_PHYSICAL_BC3D)); here the flag is 'dev'.)
!
! The test runs every open-copy variable ('u','v','w','t','d','e','f','x',
! 'y','r','p') and one that is not copied ('a') on several tile positions,
! host and target, and compares the whole array bit for bit.
! Usage: t_tmpl_g [nrep]; ALLOW_HOST=1 for host-only.

MODULE tg_mod
   IMPLICIT NONE
   INTEGER, PARAMETER :: bdyzone = 4          ! module_bc.F:33
   TYPE grid_config_rec_type
      LOGICAL :: periodic_x = .false., periodic_y = .false.
      LOGICAL :: symmetric_xs = .false., symmetric_xe = .false., symmetric_ys = .false., symmetric_ye = .false.
      LOGICAL :: open_xs = .false., open_xe = .false., open_ys = .false., open_ye = .false.
      LOGICAL :: specified = .true., nested = .false., polar = .false.
   END TYPE grid_config_rec_type
CONTAINS

! BEGIN VERBATIM WRF/share/module_bc.F
   SUBROUTINE set_physical_bc3d( dat, variable_in,        &
                               config_flags,                   &
                               ids,ide, jds,jde, kds,kde,  & ! domain dims
                               ims,ime, jms,jme, kms,kme,  & ! memory dims
                               ips,ipe, jps,jpe, kps,kpe,  & ! patch  dims
                               its,ite, jts,jte, kts,kte )

!  This subroutine sets the data in the boundary region, by direct
!  assignment if possible, for periodic and symmetric (wall)
!  boundary conditions.  Currently, we are only doing 1 variable
!  at a time - lots of overhead, so maybe this routine can be easily
!  inlined later or we could pass multiple variables -
!  would probably want a largestep and smallstep version.

!  15 Jan 99, Dave
!  Modified the incoming its,ite,jts,jte to truly be the tile size.
!  This required modifying the loop limits when the "istag" or "jstag"
!  is used, as this is only required at the end of the domain.

      IMPLICIT NONE

      INTEGER,      INTENT(IN   )    :: ids,ide, jds,jde, kds,kde
      INTEGER,      INTENT(IN   )    :: ims,ime, jms,jme, kms,kme
      INTEGER,      INTENT(IN   )    :: ips,ipe, jps,jpe, kps,kpe
      INTEGER,      INTENT(IN   )    :: its,ite, jts,jte, kts,kte
      CHARACTER,    INTENT(IN   )    :: variable_in

      CHARACTER                      :: variable

      REAL,  DIMENSION( ims:ime , kms:kme , jms:jme ) :: dat
      TYPE( grid_config_rec_type ) config_flags

      INTEGER  :: i, j, k, istag, jstag, itime, k_end, &
                  i_start, i_end

      LOGICAL  :: debug, open_bc_copy

!------------

      debug = .false.

      open_bc_copy = .false.

      variable = variable_in
      IF ( variable_in .ge. 'A' .and. variable_in .le. 'Z' ) THEN
        variable = CHAR( ICHAR(variable_in) - ICHAR('A') + ICHAR('a') )
      ENDIF

      IF ((variable == 'u') .or. (variable == 'v') .or.     &
          (variable == 'w') .or. (variable == 't') .or.     &
          (variable == 'd') .or. (variable == 'e') .or. &
          (variable == 'x') .or. (variable == 'y') .or. &
          (variable == 'f') .or. (variable == 'r') .or. &
          (variable == 'p')                        ) open_bc_copy = .true.

!  begin, first set a staggering variable

      istag = -1
      jstag = -1
      k_end = max(1,min(kde-1,kte))


      IF ((variable == 'u') .or. (variable == 'x')) istag = 0
      IF ((variable == 'v') .or. (variable == 'y')) jstag = 0
      IF ((variable == 'd') .or. (variable == 'xy')) then
         istag = 0
         jstag = 0
      ENDIF
      IF ((variable == 'e') ) then
         istag = 0
         k_end = min(kde,kte)
      ENDIF

      IF ((variable == 'f') ) then
         jstag = 0
         k_end = min(kde,kte)
      ENDIF

      IF ( variable == 'w')  k_end = min(kde,kte)

!      k_end = kte

      if(debug) then
        write(6,*) ' in bc, var is ',variable, istag, jstag, kte, k_end
        write(6,*) ' b.cs are ',  &
      config_flags%periodic_x,  &
      config_flags%periodic_y
      end if
      


!  periodic conditions.
!  note, patch must cover full range in periodic dir, or else
!  its intra-patch communication that is handled elsewheres.
!  symmetry conditions can always be handled here, because no
!  outside patch communication is needed

      periodicity_x:  IF( ( config_flags%periodic_x ) ) THEN

        IF ( ( ids == ips ) .and. ( ide == ipe ) ) THEN  ! test if both east and west on-processor
          IF ( its == ids ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = 0,-(bdyzone-1),-1
              dat(ids+i-1,k,j) = dat(ide+i-1,k,j)
            ENDDO
            ENDDO
            ENDDO

          ENDIF


          IF ( ite == ide ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = -istag , bdyzone
              dat(ide+i+istag,k,j) = dat(ids+i+istag,k,j)
            ENDDO
            ENDDO
            ENDDO

          ENDIF

        ENDIF

      ELSE

        symmetry_xs: IF( ( config_flags%symmetric_xs ) .and.  &
                         ( its == ids )                  )  THEN

          IF ( istag == -1 ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = 1, bdyzone
              dat(ids-i,k,j) = dat(ids+i-1,k,j) !  here, dat(0) = dat(1), etc
            ENDDO                                 !  symmetry about dat(0.5) (u = 0 pt)
            ENDDO
            ENDDO

          ELSE

            IF ( variable == 'u' ) THEN

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ids-i,k,j) = - dat(ids+i,k,j) ! here, u(0) = - u(2), etc
              ENDDO                                 !  normal b.c symmetry at u(1)
              ENDDO
              ENDDO

            ELSE

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ids-i,k,j) = dat(ids+i,k,j) ! here, phi(0) = phi(2), etc
              ENDDO                               !  normal b.c symmetry at phi(1)
              ENDDO
              ENDDO

            END IF

          ENDIF

        ENDIF symmetry_xs


!  now the symmetry boundary at xe

        symmetry_xe: IF( ( config_flags%symmetric_xe ) .and.  &
                         ( ite == ide )                  )  THEN

          IF ( istag == -1 ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = 1, bdyzone
              dat(ide+i-1,k,j) = dat(ide-i,k,j)  !  sym. about dat(ide-0.5)
            ENDDO
            ENDDO
            ENDDO

          ELSE

            IF (variable == 'u') THEN

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ide+i,k,j) = - dat(ide-i,k,j)  ! u(ide+1) = - u(ide-1), etc.
              ENDDO
              ENDDO
              ENDDO

            ELSE

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ide+i,k,j) = dat(ide-i,k,j)  ! phi(ide+1) = - phi(ide-1), etc.
              ENDDO
              ENDDO
              ENDDO

             END IF

          END IF

        END IF symmetry_xe

!  set open b.c in X copy into boundary zone here.  WCS, 19 March 2000

        open_xs: IF( ( config_flags%open_xs   .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( its == ids ) .and. open_bc_copy  )  THEN

            DO j = jts-bdyzone, MIN(jte,jde+jstag)+bdyzone
#if defined(INTEL_ALIGN64)
!DEC$ ASSUME_ALIGNED dat:64
!DEC$ UNROLL(4)
!DEC$ IVDEP
#endif
            DO k = kts, k_end
              dat(ids-1,k,j) = dat(ids,k,j) !  here, dat(0) = dat(1), etc
              dat(ids-2,k,j) = dat(ids,k,j)
              dat(ids-3,k,j) = dat(ids,k,j)
            ENDDO
            ENDDO

        ENDIF open_xs


!  now the open_xe boundary copy

        open_xe: IF( ( config_flags%open_xe   .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( ite == ide ) .and. open_bc_copy )  THEN

          IF (variable /= 'u' .and. variable /= 'x' ) THEN

            DO j = jts-bdyzone, MIN(jte,jde+jstag)+bdyzone
#if defined(INTEL_ALIGN64)
!DEC$ ASSUME_ALIGNED dat:64
!DEC$ UNROLL(4)
!DEC$ IVDEP
#endif
            DO k = kts, k_end
              dat(ide  ,k,j) = dat(ide-1,k,j)
              dat(ide+1,k,j) = dat(ide-1,k,j)
              dat(ide+2,k,j) = dat(ide-1,k,j)
            ENDDO
            ENDDO

          ELSE

!!!!!!! I am not sure about this one!  JM 20020402
            DO j = MAX(jds,jts-1)-bdyzone, MIN(jte+1,jde+jstag)+bdyzone
            DO k = kts, k_end
              dat(ide+1,k,j) = dat(ide,k,j)
              dat(ide+2,k,j) = dat(ide,k,j)
              dat(ide+3,k,j) = dat(ide,k,j)
            ENDDO
            ENDDO

          END IF

        END IF open_xe

!  end open b.c in X copy into boundary zone addition.  WCS, 19 March 2000

      END IF periodicity_x

!  same procedure in y

!  Set the starting and ending loop indexes in the 'i' direction, so that
!  halo cells on the edge of the domain are also updated.  Begin with a default
!  start and end index for inner tiles, and then modify if the tile is on the
!  edge of the domain.

      i_start = MAX(ids, its-1)
      i_end = MIN(ite+1, ide+istag)
      IF ( its .eq. ids) THEN
        i_start = ims
      END IF
      IF ( ite .eq. ide) THEN
        i_end = ime
      END IF

      periodicity_y:  IF( ( config_flags%periodic_y ) ) THEN
        IF ( ( jds == jps ) .and. ( jde == jpe ) )  THEN      ! test if both north and south on processor
          IF( jts == jds ) then

            DO j = 0, -(bdyzone-1), -1
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jds+j-1) = dat(i,k,jde+j-1)
            ENDDO
            ENDDO
            ENDDO

          END IF

          IF( jte == jde ) then

            DO j = -jstag, bdyzone
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde+j+jstag) = dat(i,k,jds+j+jstag)
            ENDDO
            ENDDO
            ENDDO

          END IF

        END IF

      ELSE

        symmetry_ys: IF( ( config_flags%symmetric_ys ) .and.  &
                         ( jts == jds)                   )  THEN

          IF ( jstag == -1 ) THEN

            DO j = 1, bdyzone
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jds-j) = dat(i,k,jds+j-1)
            ENDDO                               
            ENDDO
            ENDDO

          ELSE

            IF (variable == 'v') THEN

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jds-j) = - dat(i,k,jds+j)
              ENDDO              
              ENDDO
              ENDDO

            ELSE

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jds-j) = dat(i,k,jds+j)
              ENDDO              
              ENDDO
              ENDDO

            END IF

          ENDIF

        ENDIF symmetry_ys

!  now the symmetry boundary at ye

        symmetry_ye: IF( ( config_flags%symmetric_ye ) .and.  &
                         ( jte == jde )                  )  THEN

          IF ( jstag == -1 ) THEN

            DO j = 1, bdyzone
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde+j-1) = dat(i,k,jde-j)
            ENDDO                               
            ENDDO
            ENDDO

          ELSE

            IF ( variable == 'v' ) THEN

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jde+j) = - dat(i,k,jde-j)
              ENDDO                               
              ENDDO
              ENDDO

            ELSE

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jde+j) = dat(i,k,jde-j)
              ENDDO                               
              ENDDO
              ENDDO

            END IF

          ENDIF

        END IF symmetry_ye
      
!  set open b.c in Y copy into boundary zone here.  WCS, 19 March 2000

        open_ys: IF( ( config_flags%open_ys   .or. &
                       config_flags%polar     .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( jts == jds) .and. open_bc_copy )  THEN

            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jds-1) = dat(i,k,jds)
              dat(i,k,jds-2) = dat(i,k,jds)
              dat(i,k,jds-3) = dat(i,k,jds)
            ENDDO
            ENDDO

        ENDIF open_ys

!  now the open boundary copy at ye

        open_ye: IF( ( config_flags%open_ye   .or. &
                       config_flags%polar     .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( jte == jde ) .and. open_bc_copy )  THEN

          IF (variable /= 'v' .and. variable /= 'y' ) THEN

            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde  ) = dat(i,k,jde-1)
              dat(i,k,jde+1) = dat(i,k,jde-1)
              dat(i,k,jde+2) = dat(i,k,jde-1)
            ENDDO                               
            ENDDO

          ELSE

            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde+1) = dat(i,k,jde)
              dat(i,k,jde+2) = dat(i,k,jde)
              dat(i,k,jde+3) = dat(i,k,jde)
            ENDDO                               
            ENDDO

          ENDIF

      END IF open_ye

!  end open b.c in Y copy into boundary zone addition.  WCS, 19 March 2000

      END IF periodicity_y

   END SUBROUTINE set_physical_bc3d
! END VERBATIM


   SUBROUTINE set_physical_bc3d_gpu( dat, variable_in, dev, &
                               config_flags,                   &
                               ids,ide, jds,jde, kds,kde,  & ! domain dims
                               ims,ime, jms,jme, kms,kme,  & ! memory dims
                               ips,ipe, jps,jpe, kps,kpe,  & ! patch  dims
                               its,ite, jts,jte, kts,kte )

!  This subroutine sets the data in the boundary region, by direct
!  assignment if possible, for periodic and symmetric (wall)
!  boundary conditions.  Currently, we are only doing 1 variable
!  at a time - lots of overhead, so maybe this routine can be easily
!  inlined later or we could pass multiple variables -
!  would probably want a largestep and smallstep version.

!  15 Jan 99, Dave
!  Modified the incoming its,ite,jts,jte to truly be the tile size.
!  This required modifying the loop limits when the "istag" or "jstag"
!  is used, as this is only required at the end of the domain.

      IMPLICIT NONE

      INTEGER,      INTENT(IN   )    :: ids,ide, jds,jde, kds,kde
      INTEGER,      INTENT(IN   )    :: ims,ime, jms,jme, kms,kme
      INTEGER,      INTENT(IN   )    :: ips,ipe, jps,jpe, kps,kpe
      INTEGER,      INTENT(IN   )    :: its,ite, jts,jte, kts,kte
      CHARACTER,    INTENT(IN   )    :: variable_in
      LOGICAL,      INTENT(IN   )    :: dev

      CHARACTER                      :: variable

      REAL,  DIMENSION( ims:ime , kms:kme , jms:jme ) :: dat
      TYPE( grid_config_rec_type ) config_flags

      INTEGER  :: i, j, k, istag, jstag, itime, k_end, &
                  i_start, i_end

      LOGICAL  :: debug, open_bc_copy

!------------

      debug = .false.

      open_bc_copy = .false.

      variable = variable_in
      IF ( variable_in .ge. 'A' .and. variable_in .le. 'Z' ) THEN
        variable = CHAR( ICHAR(variable_in) - ICHAR('A') + ICHAR('a') )
      ENDIF

      IF ((variable == 'u') .or. (variable == 'v') .or.     &
          (variable == 'w') .or. (variable == 't') .or.     &
          (variable == 'd') .or. (variable == 'e') .or. &
          (variable == 'x') .or. (variable == 'y') .or. &
          (variable == 'f') .or. (variable == 'r') .or. &
          (variable == 'p')                        ) open_bc_copy = .true.

!  begin, first set a staggering variable

      istag = -1
      jstag = -1
      k_end = max(1,min(kde-1,kte))


      IF ((variable == 'u') .or. (variable == 'x')) istag = 0
      IF ((variable == 'v') .or. (variable == 'y')) jstag = 0
      IF ((variable == 'd') .or. (variable == 'xy')) then
         istag = 0
         jstag = 0
      ENDIF
      IF ((variable == 'e') ) then
         istag = 0
         k_end = min(kde,kte)
      ENDIF

      IF ((variable == 'f') ) then
         jstag = 0
         k_end = min(kde,kte)
      ENDIF

      IF ( variable == 'w')  k_end = min(kde,kte)

!      k_end = kte

      if(debug) then
        write(6,*) ' in bc, var is ',variable, istag, jstag, kte, k_end
        write(6,*) ' b.cs are ',  &
      config_flags%periodic_x,  &
      config_flags%periodic_y
      end if
      


!  periodic conditions.
!  note, patch must cover full range in periodic dir, or else
!  its intra-patch communication that is handled elsewheres.
!  symmetry conditions can always be handled here, because no
!  outside patch communication is needed

      periodicity_x:  IF( ( config_flags%periodic_x ) ) THEN

        IF ( ( ids == ips ) .and. ( ide == ipe ) ) THEN  ! test if both east and west on-processor
          IF ( its == ids ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = 0,-(bdyzone-1),-1
              dat(ids+i-1,k,j) = dat(ide+i-1,k,j)
            ENDDO
            ENDDO
            ENDDO

          ENDIF


          IF ( ite == ide ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = -istag , bdyzone
              dat(ide+i+istag,k,j) = dat(ids+i+istag,k,j)
            ENDDO
            ENDDO
            ENDDO

          ENDIF

        ENDIF

      ELSE

        symmetry_xs: IF( ( config_flags%symmetric_xs ) .and.  &
                         ( its == ids )                  )  THEN

          IF ( istag == -1 ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = 1, bdyzone
              dat(ids-i,k,j) = dat(ids+i-1,k,j) !  here, dat(0) = dat(1), etc
            ENDDO                                 !  symmetry about dat(0.5) (u = 0 pt)
            ENDDO
            ENDDO

          ELSE

            IF ( variable == 'u' ) THEN

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ids-i,k,j) = - dat(ids+i,k,j) ! here, u(0) = - u(2), etc
              ENDDO                                 !  normal b.c symmetry at u(1)
              ENDDO
              ENDDO

            ELSE

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ids-i,k,j) = dat(ids+i,k,j) ! here, phi(0) = phi(2), etc
              ENDDO                               !  normal b.c symmetry at phi(1)
              ENDDO
              ENDDO

            END IF

          ENDIF

        ENDIF symmetry_xs


!  now the symmetry boundary at xe

        symmetry_xe: IF( ( config_flags%symmetric_xe ) .and.  &
                         ( ite == ide )                  )  THEN

          IF ( istag == -1 ) THEN

            DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
            DO k = kts, k_end
            DO i = 1, bdyzone
              dat(ide+i-1,k,j) = dat(ide-i,k,j)  !  sym. about dat(ide-0.5)
            ENDDO
            ENDDO
            ENDDO

          ELSE

            IF (variable == 'u') THEN

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ide+i,k,j) = - dat(ide-i,k,j)  ! u(ide+1) = - u(ide-1), etc.
              ENDDO
              ENDDO
              ENDDO

            ELSE

              DO j = MAX(jds,jts-1), MIN(jte+1,jde+jstag)
              DO k = kts, k_end
              DO i = 1, bdyzone
                dat(ide+i,k,j) = dat(ide-i,k,j)  ! phi(ide+1) = - phi(ide-1), etc.
              ENDDO
              ENDDO
              ENDDO

             END IF

          END IF

        END IF symmetry_xe

!  set open b.c in X copy into boundary zone here.  WCS, 19 March 2000

        open_xs: IF( ( config_flags%open_xs   .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( its == ids ) .and. open_bc_copy  )  THEN

!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) shared(dat) &
!$omp& firstprivate(ids, ide, jds, jde, jts, jte, jstag, kts, k_end, i_start, i_end)
            DO j = jts-bdyzone, MIN(jte,jde+jstag)+bdyzone
#if defined(INTEL_ALIGN64)
!DEC$ ASSUME_ALIGNED dat:64
!DEC$ UNROLL(4)
!DEC$ IVDEP
#endif
            DO k = kts, k_end
              dat(ids-1,k,j) = dat(ids,k,j) !  here, dat(0) = dat(1), etc
              dat(ids-2,k,j) = dat(ids,k,j)
              dat(ids-3,k,j) = dat(ids,k,j)
            ENDDO
            ENDDO

        ENDIF open_xs


!  now the open_xe boundary copy

        open_xe: IF( ( config_flags%open_xe   .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( ite == ide ) .and. open_bc_copy )  THEN

          IF (variable /= 'u' .and. variable /= 'x' ) THEN

!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) shared(dat) &
!$omp& firstprivate(ids, ide, jds, jde, jts, jte, jstag, kts, k_end, i_start, i_end)
            DO j = jts-bdyzone, MIN(jte,jde+jstag)+bdyzone
#if defined(INTEL_ALIGN64)
!DEC$ ASSUME_ALIGNED dat:64
!DEC$ UNROLL(4)
!DEC$ IVDEP
#endif
            DO k = kts, k_end
              dat(ide  ,k,j) = dat(ide-1,k,j)
              dat(ide+1,k,j) = dat(ide-1,k,j)
              dat(ide+2,k,j) = dat(ide-1,k,j)
            ENDDO
            ENDDO

          ELSE

!!!!!!! I am not sure about this one!  JM 20020402
!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) shared(dat) &
!$omp& firstprivate(ids, ide, jds, jde, jts, jte, jstag, kts, k_end, i_start, i_end)
            DO j = MAX(jds,jts-1)-bdyzone, MIN(jte+1,jde+jstag)+bdyzone
            DO k = kts, k_end
              dat(ide+1,k,j) = dat(ide,k,j)
              dat(ide+2,k,j) = dat(ide,k,j)
              dat(ide+3,k,j) = dat(ide,k,j)
            ENDDO
            ENDDO

          END IF

        END IF open_xe

!  end open b.c in X copy into boundary zone addition.  WCS, 19 March 2000

      END IF periodicity_x

!  same procedure in y

!  Set the starting and ending loop indexes in the 'i' direction, so that
!  halo cells on the edge of the domain are also updated.  Begin with a default
!  start and end index for inner tiles, and then modify if the tile is on the
!  edge of the domain.

      i_start = MAX(ids, its-1)
      i_end = MIN(ite+1, ide+istag)
      IF ( its .eq. ids) THEN
        i_start = ims
      END IF
      IF ( ite .eq. ide) THEN
        i_end = ime
      END IF

      periodicity_y:  IF( ( config_flags%periodic_y ) ) THEN
        IF ( ( jds == jps ) .and. ( jde == jpe ) )  THEN      ! test if both north and south on processor
          IF( jts == jds ) then

            DO j = 0, -(bdyzone-1), -1
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jds+j-1) = dat(i,k,jde+j-1)
            ENDDO
            ENDDO
            ENDDO

          END IF

          IF( jte == jde ) then

            DO j = -jstag, bdyzone
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde+j+jstag) = dat(i,k,jds+j+jstag)
            ENDDO
            ENDDO
            ENDDO

          END IF

        END IF

      ELSE

        symmetry_ys: IF( ( config_flags%symmetric_ys ) .and.  &
                         ( jts == jds)                   )  THEN

          IF ( jstag == -1 ) THEN

            DO j = 1, bdyzone
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jds-j) = dat(i,k,jds+j-1)
            ENDDO                               
            ENDDO
            ENDDO

          ELSE

            IF (variable == 'v') THEN

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jds-j) = - dat(i,k,jds+j)
              ENDDO              
              ENDDO
              ENDDO

            ELSE

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jds-j) = dat(i,k,jds+j)
              ENDDO              
              ENDDO
              ENDDO

            END IF

          ENDIF

        ENDIF symmetry_ys

!  now the symmetry boundary at ye

        symmetry_ye: IF( ( config_flags%symmetric_ye ) .and.  &
                         ( jte == jde )                  )  THEN

          IF ( jstag == -1 ) THEN

            DO j = 1, bdyzone
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde+j-1) = dat(i,k,jde-j)
            ENDDO                               
            ENDDO
            ENDDO

          ELSE

            IF ( variable == 'v' ) THEN

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jde+j) = - dat(i,k,jde-j)
              ENDDO                               
              ENDDO
              ENDDO

            ELSE

              DO j = 1, bdyzone
              DO k = kts, k_end
              DO i = i_start, i_end
                dat(i,k,jde+j) = dat(i,k,jde-j)
              ENDDO                               
              ENDDO
              ENDDO

            END IF

          ENDIF

        END IF symmetry_ye
      
!  set open b.c in Y copy into boundary zone here.  WCS, 19 March 2000

        open_ys: IF( ( config_flags%open_ys   .or. &
                       config_flags%polar     .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( jts == jds) .and. open_bc_copy )  THEN

!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) shared(dat) &
!$omp& firstprivate(ids, ide, jds, jde, jts, jte, jstag, kts, k_end, i_start, i_end)
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jds-1) = dat(i,k,jds)
              dat(i,k,jds-2) = dat(i,k,jds)
              dat(i,k,jds-3) = dat(i,k,jds)
            ENDDO
            ENDDO

        ENDIF open_ys

!  now the open boundary copy at ye

        open_ye: IF( ( config_flags%open_ye   .or. &
                       config_flags%polar     .or. &
                       config_flags%specified .or. &
                       config_flags%nested            ) .and.  &
                         ( jte == jde ) .and. open_bc_copy )  THEN

          IF (variable /= 'v' .and. variable /= 'y' ) THEN

!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) shared(dat) &
!$omp& firstprivate(ids, ide, jds, jde, jts, jte, jstag, kts, k_end, i_start, i_end)
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde  ) = dat(i,k,jde-1)
              dat(i,k,jde+1) = dat(i,k,jde-1)
              dat(i,k,jde+2) = dat(i,k,jde-1)
            ENDDO                               
            ENDDO

          ELSE

!$omp target teams distribute parallel do collapse(2) if(target: dev) default(none) shared(dat) &
!$omp& firstprivate(ids, ide, jds, jde, jts, jte, jstag, kts, k_end, i_start, i_end)
            DO k = kts, k_end
            DO i = i_start, i_end
              dat(i,k,jde+1) = dat(i,k,jde)
              dat(i,k,jde+2) = dat(i,k,jde)
              dat(i,k,jde+3) = dat(i,k,jde)
            ENDDO                               
            ENDDO

          ENDIF

      END IF open_ye

!  end open b.c in Y copy into boundary zone addition.  WCS, 19 March 2000

      END IF periodicity_y

   END SUBROUTINE set_physical_bc3d_gpu

END MODULE tg_mod


PROGRAM t_tmpl_g
   USE tg_mod
   USE omp_lib
   IMPLICIT NONE
   INTEGER, PARAMETER :: ids = 1, ide = 31, jds = 1, jde = 26, kds = 1, kde = 16
   INTEGER, PARAMETER :: ims = -4, ime = 36, jms = -4, jme = 31, kms = 1, kme = 16
   REAL, DIMENSION(ims:ime, kms:kme, jms:jme) :: d0, da, db, dc
   TYPE(grid_config_rec_type) :: cf
   CHARACTER(LEN=12), PARAMETER :: vars = 'uvwtdefxyrpa'
   INTEGER :: irep, nrep, nbad, it, iv, nargs, tiles(4, 4), ncopied
   CHARACTER(LEN=16) :: arg, allow
   LOGICAL :: on_host
   tiles(:,1) = (/ ids, ide, jds, jde /)
   tiles(:,2) = (/ ids, 15, jds, 12 /)
   tiles(:,3) = (/ 16, ide, 13, jde /)
   tiles(:,4) = (/ 8, 20, 6, 18 /)
   nrep = 5
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
      PRINT '(a)', 'FAIL  T-TMPL-G: target regions run on the host (no GPU?).  Set ALLOW_HOST=1 for a host-only check.'
      STOP 2
   END IF
   PRINT '(a,a)', 'note: target regions run on the ', MERGE('host', 'GPU ', on_host)
   CALL RANDOM_SEED()
   nbad = 0
   ncopied = 0
   DO irep = 1, nrep
      CALL RANDOM_NUMBER(d0)
      cf%specified = MOD(irep, 2) == 1
      cf%nested = .NOT. cf%specified
      DO iv = 1, LEN(vars)
      DO it = 1, 4
         da = d0; db = d0; dc = d0
         CALL set_physical_bc3d(da, vars(iv:iv), cf, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
              ids, ide, jds, jde, kds, kde, tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), kds, kde)
         CALL set_physical_bc3d_gpu(db, vars(iv:iv), .FALSE., cf, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
              ids, ide, jds, jde, kds, kde, tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), kds, kde)
!$omp target data map(tofrom: dc)
         CALL set_physical_bc3d_gpu(dc, vars(iv:iv), .TRUE., cf, ids, ide, jds, jde, kds, kde, ims, ime, jms, jme, kms, kme, &
              ids, ide, jds, jde, kds, kde, tiles(1,it), tiles(2,it), tiles(3,it), tiles(4,it), kds, kde)
!$omp end target data
         nbad = nbad + COUNT(TRANSFER(da, 1, SIZE(da)) /= TRANSFER(db, 1, SIZE(db))) &
                     + COUNT(TRANSFER(da, 1, SIZE(da)) /= TRANSFER(dc, 1, SIZE(dc)))
         ncopied = ncopied + COUNT(da /= d0)
      END DO
      END DO
   END DO
   PRINT '(a,i0,a,i0,a)', 'T-TMPL-G: ', nrep, ' fields x 12 variables x 4 tiles, ', ncopied, ' halo values set'
   IF (nbad == 0 .AND. ncopied > 0) THEN
      PRINT '(a)', 'PASS  T-TMPL-G (set_physical_bc3d strips, original vs kernels: bit-identical)'
   ELSE
      PRINT '(a,i0,a)', 'FAIL  T-TMPL-G: ', nbad, ' differing values'
      STOP 1
   END IF
END PROGRAM t_tmpl_g
