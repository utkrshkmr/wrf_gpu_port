!WRF:DRIVER_LAYER:UTIL
!
! module_gpu_route: per-routine GPU routing switch (plan.md P0.8).
!
! Every ported target construct carries  if(target: gpu_on(R_<ROUTINE>))
! and every ported call site is wrapped in host<->device "island" updates
! that are active only when the routine is switched off (plan.md P0.8).
! Switching a routine off runs it on the host over host data, which gives
! the per-routine test T-AB-<routine>: run the same window with and without
! WRF_GPU_OFF=<routine> and compare the bit-hash traces.
!
! Environment (names are the route names below, case-insensitive, separated
! by commas or blanks):
!   WRF_GPU_OFF=name1,name2   run these routines on the host ("all" = all)
!   WRF_GPU_ONLY=name1,...    run only these routines on the device
! An unknown name stops the run, so a typo cannot silently test nothing.
!
! The route list covers every routine in plan.md 7-10; kernels are added to
! it phase by phase, and a route with no kernel yet has no effect.

MODULE module_gpu_route

   IMPLICIT NONE
   PRIVATE

   INTEGER, PARAMETER, PUBLIC :: nroutes = 101
   CHARACTER(LEN=28), PARAMETER, PUBLIC :: route_name(nroutes) = (/ &
      ! 7.1 RK preparation and physical BCs
      'initialize_moist_old        ', 'calculate_full              ', 'calc_mu_uv                  ', &
      'couple_momentum             ', 'calc_ww_cp                  ', 'calc_cq                     ', &
      'calc_alt                    ', 'calc_php                    ', 'set_physical_bc3d           ', &
      'set_physical_bc2d           ', &
      ! 7.2 large-step tendencies
      'zero_tend                   ', 'ww_split                    ', 'advect_u                    ', &
      'advect_v                    ', 'advect_w                    ', 'advect_scalar               ', &
      'rhs_ph                      ', 'horizontal_pressure_gradient', 'pg_buoy_w                   ', &
      'w_damp                      ', 'coriolis                    ', 'curvature                   ', &
      ! 7.3 tendency combination and lateral BCs
      'mass_weight                 ', 'relax_bdytend_core          ', 'rk_addtend_dry              ', &
      'spec_bdytend                ', &
      ! 7.4 acoustic loop
      'small_step_prep             ', 'calc_p_rho                  ', 'calc_coef_w                 ', &
      'advance_uv                  ', 'spec_bdyupdate              ', 'advance_mu_t                ', &
      'advance_w                   ', 'sumflux                     ', 'spec_bdyupdate_ph           ', &
      'zero_grad_bdy               ', 'small_step_finish           ', &
      ! 7.5 scalar transport
      'rk_update_scalar_pd         ', 'advect_scalar_pd            ', 'rk_update_scalar            ', &
      'flow_dep_bdy                ', 'bound_tke                   ', &
      ! 7.6 end of step
      'calc_p_rho_phi              ', 'spec_bdy_final              ', 'set_w_surface               ', &
      'update_phys_fields          ', &
      ! 7.7 turbulence
      'compute_diff_metrics        ', 'cal_deform_and_div          ', 'calculate_n2                ', &
      'smag2d_km                   ', 'tke_km                      ', 'tke_shear                   ', &
      'tke_buoyancy                ', 'calc_l_scale                ', 'tke_dissip                  ', &
      'tke_rhs                     ', 'conv_t_tendf_to_moist       ', 'vertical_diffusion_2        ', &
      'horizontal_diffusion_2      ', 'cal_titau                   ', &
      ! 8.1 physics glue
      'init_zero_tendency          ', 'phy_prep                    ', 'calculate_phy_tend          ', &
      'update_phy_ten              ', 'phy_prep_part2              ', 'moist_physics_prep_em       ', &
      'moist_physics_finish_em     ', &
      ! 8.2-8.5 schemes
      'wsm6                        ', 'surface_driver              ', 'sfclayrev                   ', &
      'lsm                         ', 'seaice_noah                 ', 'sfcdiags                    ', &
      'pbl_driver                  ', 'ysu                         ', 'radiation_driver            ', &
      'cal_cldfra1                 ', 'ozn_time_int                ', 'ozn_p_int                   ', &
      'calc_coszen                 ', 'rrtmg_lwrad                 ', 'swrad                       ', &
      ! 9.1 fire
      'interpolate_atm2fire        ', 'continue_at_boundary        ', 'interpolate_2d              ', &
      'prop_ls_rk3                 ', 'tend_ls                     ', 'fire_ros                    ', &
      'tign_update                 ', 'calc_flame_length           ', 'reinit_ls_rk3               ', &
      'advance_ls_reinit           ', 'ignite_fire                 ', 'fuel_left                   ', &
      'heat_fluxes                 ', 'sum_2d_cells                ', 'fire_tendency               ', &
      'fire_model                  ', &
      ! 10 nest forcing
      'couple_or_uncouple_em       ', 'nest_strip_pack             ', &
      ! 5 (tools)
      'bittrace                    ' /)

   ! Route indices, in the order of route_name
   INTEGER, PARAMETER, PUBLIC :: &
      R_INITIALIZE_MOIST_OLD = 1, R_CALCULATE_FULL = 2, R_CALC_MU_UV = 3, R_COUPLE_MOMENTUM = 4,        &
      R_CALC_WW_CP = 5, R_CALC_CQ = 6, R_CALC_ALT = 7, R_CALC_PHP = 8, R_SET_PHYSICAL_BC3D = 9,         &
      R_SET_PHYSICAL_BC2D = 10, R_ZERO_TEND = 11, R_WW_SPLIT = 12, R_ADVECT_U = 13, R_ADVECT_V = 14,    &
      R_ADVECT_W = 15, R_ADVECT_SCALAR = 16, R_RHS_PH = 17, R_HORIZONTAL_PRESSURE_GRADIENT = 18,          &
      R_PG_BUOY_W = 19, R_W_DAMP = 20, R_CORIOLIS = 21, R_CURVATURE = 22, R_MASS_WEIGHT = 23,            &
      R_RELAX_BDYTEND_CORE = 24, R_RK_ADDTEND_DRY = 25, R_SPEC_BDYTEND = 26, R_SMALL_STEP_PREP = 27,     &
      R_CALC_P_RHO = 28, R_CALC_COEF_W = 29, R_ADVANCE_UV = 30, R_SPEC_BDYUPDATE = 31,                  &
      R_ADVANCE_MU_T = 32, R_ADVANCE_W = 33, R_SUMFLUX = 34, R_SPEC_BDYUPDATE_PH = 35,                  &
      R_ZERO_GRAD_BDY = 36, R_SMALL_STEP_FINISH = 37, R_RK_UPDATE_SCALAR_PD = 38,                      &
      R_ADVECT_SCALAR_PD = 39, R_RK_UPDATE_SCALAR = 40, R_FLOW_DEP_BDY = 41, R_BOUND_TKE = 42,          &
      R_CALC_P_RHO_PHI = 43, R_SPEC_BDY_FINAL = 44, R_SET_W_SURFACE = 45, R_UPDATE_PHYS_FIELDS = 46,    &
      R_COMPUTE_DIFF_METRICS = 47, R_CAL_DEFORM_AND_DIV = 48, R_CALCULATE_N2 = 49, R_SMAG2D_KM = 50,    &
      R_TKE_KM = 51, R_TKE_SHEAR = 52, R_TKE_BUOYANCY = 53, R_CALC_L_SCALE = 54, R_TKE_DISSIP = 55,     &
      R_TKE_RHS = 56, R_CONV_T_TENDF_TO_MOIST = 57, R_VERTICAL_DIFFUSION_2 = 58,                       &
      R_HORIZONTAL_DIFFUSION_2 = 59, R_CAL_TITAU = 60, R_INIT_ZERO_TENDENCY = 61, R_PHY_PREP = 62,      &
      R_CALCULATE_PHY_TEND = 63, R_UPDATE_PHY_TEN = 64, R_PHY_PREP_PART2 = 65,                          &
      R_MOIST_PHYSICS_PREP_EM = 66, R_MOIST_PHYSICS_FINISH_EM = 67, R_WSM6 = 68, R_SURFACE_DRIVER = 69, &
      R_SFCLAYREV = 70, R_LSM = 71, R_SEAICE_NOAH = 72, R_SFCDIAGS = 73, R_PBL_DRIVER = 74, R_YSU = 75, &
      R_RADIATION_DRIVER = 76, R_CAL_CLDFRA1 = 77, R_OZN_TIME_INT = 78, R_OZN_P_INT = 79,               &
      R_CALC_COSZEN = 80, R_RRTMG_LWRAD = 81, R_SWRAD = 82, R_INTERPOLATE_ATM2FIRE = 83,                &
      R_CONTINUE_AT_BOUNDARY = 84, R_INTERPOLATE_2D = 85, R_PROP_LS_RK3 = 86, R_TEND_LS = 87,           &
      R_FIRE_ROS = 88, R_TIGN_UPDATE = 89, R_CALC_FLAME_LENGTH = 90, R_REINIT_LS_RK3 = 91,              &
      R_ADVANCE_LS_REINIT = 92, R_IGNITE_FIRE = 93, R_FUEL_LEFT = 94, R_HEAT_FLUXES = 95,               &
      R_SUM_2D_CELLS = 96, R_FIRE_TENDENCY = 97, R_FIRE_MODEL = 98, R_COUPLE_OR_UNCOUPLE_EM = 99,       &
      R_NEST_STRIP_PACK = 100, R_BITTRACE = 101

   ! Add a routine: append its name to route_name, add R_<NAME>, raise nroutes.

   LOGICAL, SAVE, PUBLIC :: gpu_on(nroutes) = .TRUE.
   LOGICAL, SAVE :: ready = .FALSE.

   ! Data residency for the islands (port/agent/CODING_STANDARD.md, "Islands").
   ! .TRUE. while the current values of the model arrays are in host memory:
   ! from the start through Phase 4 (the whole-solve_em bracket of plan.md
   ! P1.9 keeps the model on the host and each ported routine moves its own
   ! arguments).  Phase 5 (P5.3) sets it .FALSE. after the initial upload:
   ! then the arrays live on the device and only switched-off routes move data.
   ! A routine whose island moved data flips it for the time it runs, so the
   ! islands of routes nested inside it see where the data are.
   LOGICAL, SAVE, PUBLIC :: gpu_world_host = .TRUE.

   PUBLIC :: gpu_route_init, gpu_route_index, gpu_island

CONTAINS

   ! .TRUE. if route r runs where the current data are not, i.e. its island
   ! must move the routine's array arguments: host world and route on (copy
   ! to the device, run there, copy back), or device world and route off
   ! (copy to the host, run there, copy back).  Always .FALSE. without WRF_GPU.
   LOGICAL FUNCTION gpu_island(r)
      INTEGER, INTENT(IN) :: r
#ifdef WRF_GPU
      gpu_island = gpu_world_host .EQV. gpu_on(r)
#else
      gpu_island = .FALSE.
#endif
   END FUNCTION gpu_island

   INTEGER FUNCTION gpu_route_index(name)
      CHARACTER(LEN=*), INTENT(IN) :: name
      INTEGER :: r
      gpu_route_index = 0
      DO r = 1, nroutes
         IF (TRIM(route_name(r)) == TRIM(lower(name))) THEN
            gpu_route_index = r
            RETURN
         END IF
      END DO
   END FUNCTION gpu_route_index

   FUNCTION lower(s) RESULT(t)
      CHARACTER(LEN=*), INTENT(IN) :: s
      CHARACTER(LEN=LEN(s)) :: t
      INTEGER :: i, c
      t = s
      DO i = 1, LEN(s)
         c = ICHAR(s(i:i))
         IF (c >= ICHAR('A') .AND. c <= ICHAR('Z')) t(i:i) = CHAR(c + 32)
      END DO
   END FUNCTION lower

   ! Apply WRF_GPU_OFF / WRF_GPU_ONLY.  Safe to call more than once.
   SUBROUTINE gpu_route_init()
      USE module_wrf_error
      CHARACTER(LEN=4096) :: v
      INTEGER :: st, noff
      IF (ready) RETURN
      ready = .TRUE.
      gpu_on = .TRUE.
      CALL get_environment_variable('WRF_GPU_ONLY', v, status=st)
      IF (st == 0 .AND. LEN_TRIM(v) > 0) THEN
         gpu_on = .FALSE.
         CALL apply(v, .TRUE.)
      END IF
      CALL get_environment_variable('WRF_GPU_OFF', v, status=st)
      IF (st == 0 .AND. LEN_TRIM(v) > 0) CALL apply(v, .FALSE.)
      noff = COUNT(.NOT. gpu_on)
      IF (noff > 0) THEN
         WRITE (wrf_err_message, '(a,i0,a,i0,a)') 'gpu_route: ', noff, ' of ', nroutes, &
            ' routes run on the host (WRF_GPU_OFF / WRF_GPU_ONLY)'
         CALL wrf_message(TRIM(wrf_err_message))
      END IF
   CONTAINS
      SUBROUTINE apply(list, val)
         CHARACTER(LEN=*), INTENT(IN) :: list
         LOGICAL, INTENT(IN) :: val
         INTEGER :: p, q, r
         CHARACTER(LEN=64) :: word
         p = 1
         DO WHILE (p <= LEN_TRIM(list))
            DO WHILE (p <= LEN_TRIM(list) .AND. INDEX(', ', list(p:p)) > 0)
               p = p + 1
            END DO
            IF (p > LEN_TRIM(list)) EXIT
            q = p
            DO WHILE (q <= LEN_TRIM(list) .AND. INDEX(', ', list(q:q)) == 0)
               q = q + 1
            END DO
            word = lower(list(p:q - 1))
            IF (TRIM(word) == 'all') THEN
               gpu_on = val
            ELSE
               r = gpu_route_index(word)
               IF (r == 0) CALL wrf_error_fatal('gpu_route: unknown route name "'//TRIM(word)// &
                                                '" in WRF_GPU_OFF/WRF_GPU_ONLY')
               gpu_on(r) = val
            END IF
            p = q
         END DO
      END SUBROUTINE apply
   END SUBROUTINE gpu_route_init

END MODULE module_gpu_route
